use std::collections::VecDeque;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use accubattery::apps::Apps;
use accubattery::battery::{self, now, Battery};
use accubattery::control::{self, Action, Inputs, LocalTime};
use accubattery::db::{self, Db};
use accubattery::engine::{self, Engine, Event, Kind, Sample, Status};
use accubattery::{estimate, export, fleet, notify, ring, wake};
use serde::{Deserialize, Serialize};
use serde_json::json;

mod power;

const POLL: Duration = Duration::from_secs(10);

#[derive(Default, Serialize, Deserialize)]
struct Persist {
    engine: Engine,
    cycle_id: Option<i64>,
    alarmed_cycle: Option<i64>,
    low_cycle: Option<i64>,
    low_level: u8,
    apps: Apps,
}

/// everything the daemon keeps per battery
struct Runner {
    bat: Battery,
    st: Persist,
    ring: ring::Ring,
    wake_prev: wake::Snap,
    recent_w: VecDeque<f64>,
    apps_written: f64,
    profile_loaded: f64,
    last_wall: Option<f64>,
    eta: Option<serde_json::Value>,
}

fn persist_path(name: &str) -> PathBuf {
    db::data_dir().join(format!("engine-{name}.json"))
}

fn state_path() -> PathBuf {
    let rt = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(rt).join("accubattery/state.json")
}

fn write_atomic(path: &PathBuf, body: &str) {
    if let Some(d) = path.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let tmp = path.with_extension("tmp");
    if std::fs::write(&tmp, body).is_ok() {
        let _ = std::fs::rename(tmp, path);
    }
}

fn load_persist(db: &Db, name: &str, primary: bool) -> Persist {
    let read = |p: PathBuf| std::fs::read_to_string(p).ok().and_then(|s| serde_json::from_str::<Persist>(&s).ok());
    let mut p = read(persist_path(name)).or_else(|| primary.then(|| read(db::data_dir().join("engine.json"))).flatten()).unwrap_or_default();
    // the row may have been deleted by hand; start clean rather than write telemetry into the void
    if p.cycle_id.is_some_and(|id| !db.open_row(id)) {
        p.cycle_id = None;
        p.engine.active = None;
    }
    p
}

fn apply(db: &Db, r: &mut Runner, ev: Vec<Event>, pd: Option<&str>) {
    let name = r.bat.name.clone();
    for e in ev {
        let res = match e {
            Event::Open { kind, at } => {
                r.st.apps.reset();
                r.apps_written = 0.0;
                db.open_cycle(kind, &at, &name).map(|id| r.st.cycle_id = Some(id))
            }
            Event::Telemetry(s) => match r.st.cycle_id {
                Some(id) => db.telemetry(id, &s),
                None => Ok(()),
            },
            Event::Close { start, at, kind } => match r.st.cycle_id.take() {
                Some(id) => {
                    if kind == Kind::Discharge && !r.st.apps.wh.is_empty() {
                        let _ = db.set_top_apps(id, &r.st.apps.top_json(10));
                    }
                    db.close_cycle(id, &start, &at, if kind == Kind::Charge { pd } else { None })
                }
                None => Ok(()),
            },
            Event::Offline { kind, cause, from, to, est_s } => {
                let wake_json = (cause == engine::GapCause::Suspend).then(|| wake::culprits(&r.wake_prev, &wake::snapshot())).flatten();
                if kind == Kind::Charge && to.pct - from.pct >= 1.0 {
                    notify::publish(
                        "battery.offline_charge",
                        json!({"battery": name, "from": from.pct.round(), "to": to.pct.round(), "off": cause == engine::GapCause::PowerOff}),
                        false,
                        &format!("Charged {:.0}% to {:.0}% while away", from.pct, to.pct),
                    );
                }
                db.offline_cycle(kind, cause, &from, &to, est_s, &name, wake_json.as_deref())
            }
            Event::Glitch { reason, from, to } => {
                db.event(to.wall, &name, "glitch", &format!("{reason}: {:.2} Wh to {:.2} Wh, capacity {:.1} Wh to {:.1} Wh", from.wh, to.wh, from.full_wh, to.full_wh))
            }
        };
        if let Err(e) = res {
            eprintln!("accubattery: db: {e}");
        }
    }
}

fn alerts(r: &mut Runner, db: &Db, s: &Sample) {
    let Some(id) = r.st.cycle_id else { return };
    if s.status == Status::Charging && r.st.alarmed_cycle != Some(id) {
        let enabled = db.setting("alarm_enabled").map(|v| !v.eq_ignore_ascii_case("false")).unwrap_or(true);
        let target: f64 = db.setting("alarm_target").and_then(|v| v.parse().ok()).unwrap_or(80.0);
        if enabled && s.pct >= target {
            r.st.alarmed_cycle = Some(id);
            notify::publish("battery.target", json!({"value": s.pct.round(), "target": target}), false, &format!("Target charge reached: {:.0}%", s.pct));
        }
    }
    if s.status == Status::Discharging {
        if r.st.low_cycle != Some(id) {
            r.st.low_cycle = Some(id);
            r.st.low_level = 0;
        }
        let level = if s.pct <= 10.0 { 2 } else if s.pct <= 20.0 { 1 } else { 0 };
        if level > r.st.low_level {
            r.st.low_level = level;
            notify::publish("battery.low", json!({"value": s.pct.round(), "critical": level == 2}), level == 2, &format!("Battery low: {:.0}%", s.pct));
        }
    }
}

fn eta(r: &Runner, s: &Sample, baseline: &[Option<f64>; 168], how: usize, target: f64) -> Option<serde_json::Value> {
    match s.status {
        Status::Discharging => {
            let w: Vec<f64> = r.recent_w.iter().copied().collect();
            let h = estimate::hours_to_empty(s.wh, estimate::decayed_watts(&w)?, baseline, how)?;
            Some(json!({"kind": "empty", "minutes": (h * 60.0).round()}))
        }
        Status::Charging => {
            let t = estimate::secs_to_target(&r.st.engine.profile, s.pct, target.max(s.pct), s.full_wh, s.watts)?;
            Some(json!({"kind": "target", "target": target.max(s.pct), "minutes": (t / 60.0).round()}))
        }
        Status::Idle => None,
    }
}

fn daemon() -> ExitCode {
    let bats = Battery::find_all();
    if bats.is_empty() {
        return ExitCode::SUCCESS;
    }
    let db = match Db::open() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("accubattery: cannot open db: {e}");
            return ExitCode::FAILURE;
        }
    };
    let mut runners: Vec<Runner> = bats
        .into_iter()
        .enumerate()
        .map(|(i, bat)| Runner {
            st: load_persist(&db, &bat.name, i == 0),
            ring: ring::Ring::new(&db::data_dir(), &bat.name),
            bat,
            wake_prev: wake::snapshot(),
            recent_w: VecDeque::new(),
            apps_written: 0.0,
            profile_loaded: 0.0,
            last_wall: None,
            eta: None,
        })
        .collect();
    let keep: Vec<i64> = runners.iter().filter_map(|r| r.st.cycle_id).collect();
    match db.repair(&keep, now()) {
        Ok(n) if n > 0 => eprintln!("accubattery: repaired {n} unfinished rows"),
        _ => {}
    }

    let summary = Arc::new(Mutex::new(String::new()));
    fleet::serve(summary.clone());
    let mut policy = power::PowerPolicy::new();
    let mut last_health = 0.0;
    let mut baseline = db.baseline();
    let mut baseline_at = 0.0;
    let mut local: Option<(f64, LocalTime)> = None;
    let mut ac_off_since: Option<f64> = None;
    let mut last_control = 0.0;

    loop {
        let t_now = now();
        let lt = match &local {
            Some((t, l)) if t_now - t < 30.0 => l.clone(),
            _ => {
                let l = control::local_time(t_now);
                local = Some((t_now, l.clone()));
                l
            }
        };
        let how = (lt.dow * 24 + lt.minute / 60) as usize;
        if t_now - baseline_at > 600.0 {
            baseline = db.baseline();
            baseline_at = t_now;
        }
        let target: f64 = db.setting("alarm_target").and_then(|v| v.parse().ok()).unwrap_or(80.0);
        // off by default: blocking lid-close sleep is the user's call, offline detection covers the gaps
        let keep_awake = db.setting("keep_awake_charging").is_some_and(|v| v.eq_ignore_ascii_case("true"));

        let mut states = serde_json::Map::new();
        let mut primary: Option<(Sample, Status)> = None;
        let mut active_kind_primary = None;
        let mut pinfo = None;

        for (i, r) in runners.iter_mut().enumerate() {
            let Some(s) = r.bat.sample() else { continue };
            r.ring.push(&s);
            let pd = battery::pd_label(&s);
            let adapter = battery::adapter_key(&s);
            let dt = r.last_wall.map(|w| (s.wall - w).clamp(0.0, 60.0)).unwrap_or(0.0);

            let ev = r.st.engine.step(s.clone());
            apply(&db, r, ev, pd.as_deref());
            r.wake_prev = wake::snapshot();
            alerts(r, &db, &s);

            if s.status == Status::Charging && s.ac && s.watts > 3.0 {
                let _ = db.profile_update(&adapter, s.pct, s.watts);
            }
            if t_now - r.profile_loaded > 300.0 {
                let p = db.profile_load(&adapter);
                if p.iter().any(|w| *w > 0.0) {
                    r.st.engine.profile = p;
                }
                r.profile_loaded = t_now;
            }
            if s.status == Status::Discharging {
                let _ = db.hourly(how as i64, s.watts);
                r.recent_w.push_back(s.watts);
                if r.recent_w.len() > 40 {
                    r.recent_w.pop_front();
                }
                if r.st.cycle_id.is_some() {
                    r.st.apps.sample(dt, s.watts);
                    if s.wall - r.apps_written > 60.0 {
                        r.apps_written = s.wall;
                        if let Some(id) = r.st.cycle_id {
                            let _ = db.set_top_apps(id, &r.st.apps.top_json(10));
                        }
                    }
                }
            } else {
                r.recent_w.clear();
            }
            if s.ac && dt > 0.0 {
                let _ = db.daily_add(&lt.date, if s.pct > 90.0 { dt } else { 0.0 }, dt);
            }
            r.last_wall = Some(s.wall);
            r.eta = eta(r, &s, &baseline, how, target);

            let active = r.st.engine.active.as_ref();
            states.insert(
                r.bat.name.clone(),
                json!({
                    "cycle_id": r.st.cycle_id,
                    "kind": active.map(|a| a.kind.as_str()),
                    "start_time": active.map(|a| a.start.wall),
                    "start_pct": active.map(|a| a.start.pct),
                    "pct": s.pct,
                    "eta": r.eta,
                }),
            );
            write_atomic(&persist_path(&r.bat.name), &serde_json::to_string(&r.st).unwrap_or_default());

            if i == 0 {
                if s.full_wh > 0.0 && r.bat.design_wh() > 0.0 {
                    let h = s.full_wh / r.bat.design_wh() * 100.0;
                    if (h - last_health).abs() >= 0.1 {
                        last_health = h;
                        let _ = db.degradation(&lt.date, h, s.full_wh, r.bat.design_wh(), r.bat.cycle_count(), s.wall);
                    }
                }
                active_kind_primary = active.map(|a| a.kind);
                pinfo = Some(policy.update(s.status == Status::Charging, s.status == Status::Idle, keep_awake, t_now));
                primary = Some((s.clone(), s.status));
            }
        }

        // trip, schedule and the charge limit belong to the primary battery
        if let (Some((s, _)), Some(r0)) = (&primary, runners.first()) {
            if s.ac {
                ac_off_since = None;
            } else {
                ac_off_since.get_or_insert(t_now);
            }
            if t_now - last_control >= 10.0 {
                last_control = t_now;
                let trip = control::load_trip();
                let sched = (db.setting("sched_enabled").is_some_and(|v| v.eq_ignore_ascii_case("true")))
                    .then(|| {
                        let dow = db.setting("sched_dow").and_then(|v| v.parse().ok()).unwrap_or(0);
                        let min = db.setting("sched_time").and_then(|v| control::parse_hhmm(&v)).unwrap_or(390);
                        let lead: u32 = db.setting("sched_lead_h").and_then(|v| v.parse().ok()).unwrap_or(3);
                        (dow, min, lead * 60)
                    });
                let done = db.setting("sched_last");
                let action = control::decide(&Inputs {
                    now: t_now,
                    ac: s.ac,
                    ac_off_for: ac_off_since.map(|t| t_now - t).unwrap_or(0.0),
                    travel_active: control::is_travel(&r0.bat),
                    trip: trip.as_ref(),
                    local: &lt,
                    sched,
                    sched_done_for: done.as_deref(),
                });
                match action {
                    Action::None => {}
                    Action::End(why) => {
                        let r = control::end_trip(&r0.bat, Some(&db));
                        notify::publish("battery.trip", json!({"state": "ended", "reason": why, "ok": r.is_ok()}), false, "Charge limit restored");
                    }
                    Action::Reapply => {
                        let _ = control::set_mode(&r0.bat, control::Mode::Travel, Some(&db));
                    }
                    Action::StartScheduled(hours) => {
                        let sc = sched.unwrap_or((0, 0, 0));
                        let _ = db.0.execute("INSERT OR REPLACE INTO settings (key,value) VALUES ('sched_last', ?)", [format!("{}@{}", lt.date, sc.0)]);
                        let r = control::start_trip(&r0.bat, hours, true, t_now, Some(&db));
                        notify::publish("battery.trip", json!({"state": "started", "scheduled": true, "ok": r.is_ok()}), false, "Charging to full for your schedule");
                    }
                }
            }
        }

        if let (Some((s, _)), Some(r0)) = (&primary, runners.first()) {
            let line = json!({
                "host": battery::hostname(),
                "pct": s.pct.round(),
                "status": format!("{:?}", s.status),
                "ac": s.ac,
                "eta": r0.eta,
                "health": if r0.bat.design_wh() > 0.0 { (s.full_wh / r0.bat.design_wh() * 1000.0).round() / 10.0 } else { 0.0 },
                "updated": s.wall,
            })
            .to_string();
            if let Ok(mut g) = summary.lock() {
                *g = line.clone();
            }
            write_atomic(&db::data_dir().join("summary.json"), &line);
            let first = states.values().next().cloned().unwrap_or_default();
            write_atomic(
                &state_path(),
                &json!({
                    "updated": s.wall,
                    "cycle_id": first["cycle_id"],
                    "kind": active_kind_primary.map(|k| k.as_str()),
                    "start_time": first["start_time"],
                    "start_pct": first["start_pct"],
                    "eta": r0.eta,
                    "batteries": states,
                    "power": pinfo,
                    "pd": battery::pd_label(s),
                    "trip": control::load_trip(),
                })
                .to_string(),
            );
        }
        std::thread::sleep(POLL);
    }
}

fn status(line: bool) -> ExitCode {
    let Ok(s) = std::fs::read_to_string(state_path()) else {
        eprintln!("accubattery: daemon is not running");
        return ExitCode::FAILURE;
    };
    if !line {
        println!("{s}");
        return ExitCode::SUCCESS;
    }
    let v: serde_json::Value = serde_json::from_str(&s).unwrap_or_default();
    let b = v["batteries"].as_object().and_then(|m| m.values().next().cloned()).unwrap_or_default();
    let eta = v["eta"]["minutes"].as_f64().map(|m| format!(", {}", fmt_min(m))).unwrap_or_default();
    println!("{:.0} %{eta}", b["pct"].as_f64().unwrap_or(0.0));
    ExitCode::SUCCESS
}

fn fmt_min(m: f64) -> String {
    let m = m as i64;
    if m >= 60 { format!("{} h {:02} min", m / 60, m % 60) } else { format!("{m} min") }
}

fn replay(path: &str) -> ExitCode {
    let samples = ring::load(std::path::Path::new(path));
    if samples.is_empty() {
        eprintln!("accubattery: no samples in {path}");
        return ExitCode::FAILURE;
    }
    let mut e = Engine::default();
    for s in samples {
        for ev in e.step(s) {
            if !matches!(ev, Event::Telemetry(_)) {
                println!("{}", engine::describe(&ev));
            }
        }
    }
    ExitCode::SUCCESS
}

fn cli_export(args: &[String]) -> ExitCode {
    let fmt = args.first().map(String::as_str).unwrap_or("csv");
    let Ok(db) = Db::open() else { return ExitCode::FAILURE };
    let body = match fmt {
        "csv" => export::csv(&db),
        "json" => export::json(&db),
        _ => {
            eprintln!("usage: accubattery export csv|json [PATH]");
            return ExitCode::from(2);
        }
    };
    match (body, args.get(1)) {
        (Ok(b), Some(p)) => std::fs::write(p, b).map_or_else(|e| { eprintln!("{e}"); ExitCode::FAILURE }, |_| ExitCode::SUCCESS),
        (Ok(b), None) => { print!("{b}"); ExitCode::SUCCESS }
        (Err(e), _) => { eprintln!("{e}"); ExitCode::FAILURE }
    }
}

fn cli_control(cmd: &str, args: &[String]) -> ExitCode {
    let Some(bat) = Battery::find() else { return ExitCode::FAILURE };
    let db = Db::open().ok();
    let report = |r: Result<(), String>| match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => { eprintln!("accubattery: {e}"); ExitCode::FAILURE }
    };
    match (cmd, args.first().map(String::as_str)) {
        ("trip", Some("--cancel")) => report(control::end_trip(&bat, db.as_ref())),
        ("trip", h) => {
            let hours: f64 = h.and_then(|v| v.parse().ok()).unwrap_or(12.0);
            report(control::start_trip(&bat, hours, false, now(), db.as_ref()).map(|_| ()))
        }
        ("limit", Some("full")) => report(control::set_mode(&bat, control::Mode::Travel, db.as_ref())),
        ("limit", Some("conserve")) => report(control::end_trip(&bat, db.as_ref())),
        ("abm", Some(l)) => match l.parse::<u8>() {
            Ok(l) if l <= 4 => report(battery::set_abm(l).map_err(|e| e.to_string())),
            _ => { eprintln!("usage: accubattery abm 0..4"); ExitCode::from(2) }
        },
        _ => { eprintln!("usage: accubattery trip [HOURS|--cancel] | limit full|conserve | abm 0..4"); ExitCode::from(2) }
    }
}

fn cli_schedule(args: &[String]) -> ExitCode {
    let Ok(db) = Db::open() else { return ExitCode::FAILURE };
    let set = |k: &str, v: &str| { let _ = db.0.execute("INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)", [k, v]); };
    match args.first().map(String::as_str) {
        Some("off") => { set("sched_enabled", "false"); ExitCode::SUCCESS }
        Some(day) => {
            let (Some(d), Some(t)) = (control::parse_day(day), args.get(1).and_then(|t| control::parse_hhmm(t))) else {
                eprintln!("usage: accubattery schedule off | DAY HH:MM [LEAD_HOURS]");
                return ExitCode::from(2);
            };
            set("sched_enabled", "true");
            set("sched_dow", &d.to_string());
            set("sched_time", &format!("{:02}:{:02}", t / 60, t % 60));
            set("sched_lead_h", args.get(2).map(String::as_str).unwrap_or("3"));
            ExitCode::SUCCESS
        }
        None => {
            for k in ["sched_enabled", "sched_dow", "sched_time", "sched_lead_h"] {
                println!("{k}={}", db.setting(k).unwrap_or_default());
            }
            ExitCode::SUCCESS
        }
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rest = args.get(1..).unwrap_or(&[]);
    match args.first().map(String::as_str) {
        None | Some("daemon") => daemon(),
        Some("status") => status(rest.iter().any(|a| a == "--line")),
        Some("replay") => rest.first().map_or(ExitCode::from(2), |p| replay(p)),
        Some("export") => cli_export(rest),
        Some("schedule") => cli_schedule(rest),
        Some(c @ ("trip" | "limit" | "abm")) => cli_control(c, rest),
        Some(_) => {
            eprintln!("usage: accubattery [daemon | status [--line] | replay FILE | export csv|json [PATH] | trip | limit | abm | schedule]");
            ExitCode::from(2)
        }
    }
}

