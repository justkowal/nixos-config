//! Everything the window shows is fetched here, on a worker thread, as one Snapshot.

use accubattery::battery::Battery;
use accubattery::db::Db;
use accubattery::engine::Sample;
use accubattery::estimate;
use serde_json::Value;

#[derive(Clone, Debug, Default)]
pub struct Cycle {
    pub id: i64,
    pub battery: String,
    pub session: String,
    pub kind: String,
    pub start: f64,
    pub duration_min: f64,
    pub start_pct: f64,
    pub end_pct: f64,
    pub wear: f64,
    pub wh: f64,
    pub mah: f64,
    pub avg_w: f64,
    pub max_w: f64,
    pub avg_t: f64,
    pub max_t: f64,
    pub pd: Option<String>,
    pub apps: Vec<(String, f64, f64)>,
    pub wake: Vec<(String, u64, u64)>,
}

#[derive(Clone, Copy, Debug)]
pub struct Point {
    pub t: f64,
    pub pct: f64,
    pub watts: f64,
}

#[derive(Default)]
pub struct Snapshot {
    pub live: Option<Sample>,
    pub battery_name: String,
    pub battery_count: usize,
    pub cycle_count: i64,
    pub design_wh: f64,
    pub state: Option<Value>,
    pub daemon_up: bool,
    pub active: Vec<Point>,
    pub active_apps: Vec<(String, f64, f64)>,
    pub cycles: Vec<Cycle>,
    pub events: Vec<(f64, String)>,
    pub health: Vec<(f64, f64)>,
    /// (percent per day, unix time of the projected floor)
    pub projection: Option<(f64, f64)>,
    pub habit: Option<(u32, &'static str)>,
    pub above_90_h: f64,
    pub standby: Vec<(String, f64, Option<String>)>,
    pub alarm_enabled: bool,
    pub alarm_target: f64,
    pub stop_threshold: Option<i64>,
    pub abm: Option<i64>,
    pub trip_until: Option<f64>,
    pub sched_enabled: bool,
    pub sched_dow: u32,
    pub sched_time: String,
    pub sched_lead_h: u32,
}

fn state_file() -> std::path::PathBuf {
    let rt = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    std::path::Path::new(&rt).join("accubattery/state.json")
}

pub fn points(db: &Db, cycle_id: i64) -> Vec<Point> {
    let Ok(mut st) = db.0.prepare("SELECT timestamp,capacity_pct,power_w FROM telemetry WHERE cycle_id=? ORDER BY timestamp") else {
        return Vec::new();
    };
    let rows = st.query_map([cycle_id], |r| Ok(Point { t: r.get(0)?, pct: r.get(1)?, watts: r.get(2)? }));
    let mut v: Vec<Point> = rows.map(|r| r.flatten().collect()).unwrap_or_default();
    // the graph cannot show more than a few hundred columns anyway
    if v.len() > 600 {
        let step = v.len() / 400;
        v = v.into_iter().step_by(step.max(1)).collect();
    }
    v
}

fn parse_apps(json: Option<String>) -> Vec<(String, f64, f64)> {
    let v: Value = json.and_then(|j| serde_json::from_str(&j).ok()).unwrap_or(Value::Null);
    v.as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| Some((x["name"].as_str()?.to_string(), x["energy_wh"].as_f64()?, x["pct_share"].as_f64().unwrap_or(0.0))))
                .collect()
        })
        .unwrap_or_default()
}

fn parse_wake(json: Option<String>) -> Vec<(String, u64, u64)> {
    let v: Value = json.and_then(|j| serde_json::from_str(&j).ok()).unwrap_or(Value::Null);
    v.as_array()
        .map(|a| a.iter().filter_map(|x| Some((x["name"].as_str()?.to_string(), x["count"].as_u64()?, x["ms"].as_u64().unwrap_or(0)))).collect())
        .unwrap_or_default()
}

fn read_i64(p: &std::path::Path) -> Option<i64> {
    std::fs::read_to_string(p).ok()?.trim().parse().ok()
}

pub fn snapshot(bats: &[Battery]) -> Snapshot {
    let bat = &bats[0];
    let live = bat.sample();
    let state: Option<Value> = std::fs::read_to_string(state_file()).ok().and_then(|s| serde_json::from_str(&s).ok());
    let daemon_up = state.as_ref().and_then(|s| s["updated"].as_f64()).is_some_and(|t| accubattery::battery::now() - t < 40.0);

    let mut snap = Snapshot {
        live,
        battery_name: bat.name.clone(),
        battery_count: bats.len(),
        cycle_count: bat.cycle_count(),
        design_wh: bat.design_wh(),
        stop_threshold: bat.thresholds().0,
        abm: accubattery::battery::abm_files().first().and_then(|p| read_i64(p)),
        trip_until: state.as_ref().and_then(|s| s["trip"]["until"].as_f64()),
        state,
        daemon_up,
        alarm_enabled: true,
        alarm_target: 80.0,
        sched_time: "06:30".into(),
        sched_lead_h: 3,
        ..Default::default()
    };
    let Ok(db) = Db::open() else { return snap };
    let setting = |k: &str| db.setting(k);
    snap.alarm_enabled = setting("alarm_enabled").map(|v| !v.eq_ignore_ascii_case("false")).unwrap_or(true);
    snap.alarm_target = setting("alarm_target").and_then(|v| v.parse().ok()).unwrap_or(80.0);
    snap.sched_enabled = setting("sched_enabled").is_some_and(|v| v.eq_ignore_ascii_case("true"));
    snap.sched_dow = setting("sched_dow").and_then(|v| v.parse().ok()).unwrap_or(0);
    snap.sched_time = setting("sched_time").unwrap_or_else(|| "06:30".into());
    snap.sched_lead_h = setting("sched_lead_h").and_then(|v| v.parse().ok()).unwrap_or(3);

    if let Some(id) = snap.state.as_ref().and_then(|s| s["cycle_id"].as_i64()) {
        snap.active = points(&db, id);
        let json: Option<String> = db.0.query_row("SELECT top_apps_json FROM cycles WHERE id=?", [id], |r| r.get(0)).ok();
        snap.active_apps = parse_apps(json);
    }
    if let Ok(mut st) = db.0.prepare(
        "SELECT id,battery,session_type,kind,start_time,duration_min,start_pct,end_pct,wear_cycles,energy_wh,energy_mah,
                avg_power_w,max_power_w,avg_temp_c,max_temp_c,pd_standard,top_apps_json,wake_json
         FROM cycles WHERE duration_min>0.3 ORDER BY start_time DESC LIMIT 300",
    ) {
        if let Ok(rows) = st.query_map([], |r| {
            Ok(Cycle {
                id: r.get(0)?,
                battery: r.get(1)?,
                session: r.get(2)?,
                kind: r.get(3)?,
                start: r.get(4)?,
                duration_min: r.get(5)?,
                start_pct: r.get(6)?,
                end_pct: r.get(7)?,
                wear: r.get(8)?,
                wh: r.get(9)?,
                mah: r.get(10)?,
                avg_w: r.get(11)?,
                max_w: r.get(12)?,
                avg_t: r.get(13)?,
                max_t: r.get(14)?,
                pd: r.get(15)?,
                apps: parse_apps(r.get(16)?),
                wake: parse_wake(r.get(17)?),
            })
        }) {
            snap.cycles = rows.flatten().collect();
        }
    }
    if let Ok(mut st) = db.0.prepare("SELECT ts,detail FROM events ORDER BY id DESC LIMIT 8") {
        if let Ok(rows) = st.query_map([], |r| Ok((r.get::<_, f64>(0)?, r.get::<_, String>(1)?))) {
            snap.events = rows.flatten().collect();
        }
    }
    if let Ok(mut st) = db.0.prepare("SELECT timestamp,health_pct FROM degradation ORDER BY id LIMIT 800") {
        if let Ok(rows) = st.query_map([], |r| Ok((r.get::<_, f64>(0)?, r.get::<_, f64>(1)?))) {
            snap.health = rows.flatten().collect();
        }
    }
    snap.projection = estimate::project_health(&snap.health, 80.0, 30.0, 8);

    let now = accubattery::battery::now();
    let charges: Vec<&Cycle> = snap.cycles.iter().filter(|c| c.session == "charge" && now - c.start < 30.0 * 86400.0).collect();
    let in_band = charges.iter().filter(|c| (20.0..=80.0).contains(&c.end_pct)).count();
    let (above, ac): (f64, f64) = db
        .0
        .query_row(
            "SELECT IFNULL(SUM(secs_above_90),0),IFNULL(SUM(secs_on_ac),0) FROM daily WHERE date_str >= date('now','-30 day')",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap_or((0.0, 0.0));
    snap.above_90_h = above / 3600.0;
    snap.habit = estimate::habit(charges.len(), in_band, above, ac);

    // standby drain per night: sleep_drain rows grouped by the day they started, in mW
    let mut nights: Vec<(String, f64, f64, Option<String>)> = Vec::new();
    for c in snap.cycles.iter().filter(|c| c.kind == "sleep_drain" && now - c.start < 8.0 * 86400.0) {
        let day = glib_day(c.start);
        let culprit = c.wake.first().map(|w| w.0.clone());
        match nights.iter_mut().find(|n| n.0 == day) {
            Some(n) => {
                n.1 += c.wh;
                n.2 += c.duration_min / 60.0;
                n.3 = n.3.take().or(culprit);
            }
            None => nights.push((day, c.wh, c.duration_min / 60.0, culprit)),
        }
    }
    snap.standby = nights.into_iter().filter(|n| n.2 > 0.5).map(|(d, wh, h, c)| (d, wh / h * 1000.0, c)).collect();
    snap
}

fn glib_day(t: f64) -> String {
    gtk4::glib::DateTime::from_unix_local(t as i64)
        .ok()
        .and_then(|d| d.format("%a %d %b").ok())
        .map(|s| s.to_string())
        .unwrap_or_default()
}

pub fn set_setting(key: &str, value: &str) {
    if let Ok(db) = Db::open() {
        let _ = db.0.execute("INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)", [key, value]);
    }
}
