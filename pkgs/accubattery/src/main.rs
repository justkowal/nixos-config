use accubattery::{battery, db, engine};
mod power;

use std::path::PathBuf;
use std::process::{Command, ExitCode, Stdio};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::json;

use battery::{now, Battery};
use db::Db;
use engine::{Engine, Event, Kind, Sample, Status};

const POLL: Duration = Duration::from_secs(10);

#[derive(Default, Serialize, Deserialize)]
struct Persist {
    engine: Engine,
    cycle_id: Option<i64>,
    alarmed_cycle: Option<i64>,
}

fn persist_path() -> PathBuf {
    db::data_dir().join("engine.json")
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

fn load_persist(db: &Db) -> Persist {
    let mut p: Persist = std::fs::read_to_string(persist_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    // the row may have been deleted by hand; start clean rather than write telemetry into the void
    if p.cycle_id.is_some_and(|id| !db.open_row(id)) {
        p.cycle_id = None;
        p.engine.active = None;
    }
    p
}

fn alarm(db: &Db, s: &Sample, st: &mut Persist) {
    let Some(id) = st.cycle_id else { return };
    if s.status != Status::Charging || st.alarmed_cycle == Some(id) {
        return;
    }
    let enabled = db.setting("alarm_enabled").map(|v| !v.eq_ignore_ascii_case("false")).unwrap_or(true);
    let target: f64 = db.setting("alarm_target").and_then(|v| v.parse().ok()).unwrap_or(80.0);
    if !enabled || s.pct < target {
        return;
    }
    st.alarmed_cycle = Some(id);
    let _ = Command::new("swayosd-client")
        .args(["--custom-message", &format!("Target charge reached: {:.0}%", s.pct), "--custom-icon", "battery-good"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

fn apply(db: &Db, st: &mut Persist, ev: Vec<Event>, pd: Option<&str>) {
    for e in ev {
        let r = match e {
            Event::Open { kind, at } => db.open_cycle(kind, &at).map(|id| st.cycle_id = Some(id)),
            Event::Telemetry(s) => match st.cycle_id {
                Some(id) => db.telemetry(id, &s),
                None => Ok(()),
            },
            Event::Close { start, at, kind, .. } => {
                match st.cycle_id.take() {
                    Some(id) => db.close_cycle(id, &start, &at, if kind == Kind::Charge { pd } else { None }),
                    None => Ok(()),
}
            }
            Event::Offline { kind, cause, from, to, est_s } => db.offline_cycle(kind, cause, &from, &to, est_s),
        };
        if let Err(e) = r {
            eprintln!("accubattery: db: {e}");
        }
    }
}

fn daemon() -> ExitCode {
    let Some(bat) = Battery::find() else { return ExitCode::SUCCESS };
    let db = match Db::open() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("accubattery: cannot open db: {e}");
            return ExitCode::FAILURE;
        }
    };
    let mut st = load_persist(&db);
    let mut policy = power::PowerPolicy::new();
    let mut last_health = 0.0;

    loop {
        if let Some(s) = bat.sample() {
            let pd = battery::pd_label(&s);
            let ev = st.engine.step(s.clone());
            apply(&db, &mut st, ev, pd.as_deref());
            alarm(&db, &s, &mut st);

            let idle_full = s.status == Status::Idle;
            let pinfo = policy.update(s.status == Status::Charging, idle_full, now());

            let t = chrono_like(s.wall);
            let _ = db.hourly(t.0, s.watts);
            if s.full_wh > 0.0 && bat.design_wh() > 0.0 {
                let h = s.full_wh / bat.design_wh() * 100.0;
                if (h - last_health).abs() >= 0.1 {
                    last_health = h;
                    let _ = db.degradation(&t.1, h, s.full_wh, bat.design_wh(), bat.cycle_count(), s.wall);
                }
            }

            let active = st.engine.active.as_ref();
            write_atomic(
                &state_path(),
                &json!({
                    "updated": s.wall,
                    "cycle_id": st.cycle_id,
                    "kind": active.map(|a| a.kind.as_str()),
                    "start_time": active.map(|a| a.start.wall),
                    "start_pct": active.map(|a| a.start.pct),
                    "power": pinfo,
                    "pd": pd,
                })
                .to_string(),
            );
            write_atomic(&persist_path(), &serde_json::to_string(&st).unwrap_or_default());
        }
        std::thread::sleep(POLL);
    }
}

/// (hour of week with Monday = 0, YYYY-MM-DD) in local time, via `date` to avoid a tz dependency
fn chrono_like(ts: f64) -> (i64, String) {
    let out = Command::new("date")
        .args(["-d", &format!("@{}", ts as i64), "+%u %H %F"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let mut it = out.split_whitespace();
    let dow: i64 = it.next().and_then(|v| v.parse().ok()).unwrap_or(1);
    let hour: i64 = it.next().and_then(|v| v.parse().ok()).unwrap_or(0);
    ((dow - 1) * 24 + hour, it.next().unwrap_or("").to_string())
}

fn status() -> ExitCode {
    match std::fs::read_to_string(state_path()) {
        Ok(s) => {
            println!("{s}");
            ExitCode::SUCCESS
        }
        Err(_) => {
            eprintln!("accubattery: daemon is not running");
            ExitCode::FAILURE
        }
    }
}

fn main() -> ExitCode {
    match std::env::args().nth(1).as_deref() {
        None | Some("daemon") => daemon(),
        Some("status") => status(),
        Some(_) => {
            eprintln!("usage: accubattery [daemon|status]");
            ExitCode::from(2)
        }
    }
}
