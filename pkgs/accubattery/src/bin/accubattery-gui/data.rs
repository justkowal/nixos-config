//! Everything the window shows is fetched here, on a worker thread, as one Snapshot.

use accubattery::battery::Battery;
use accubattery::db::Db;
use accubattery::engine::Sample;
use serde_json::Value;

#[derive(Clone, Debug)]
pub struct Cycle {
    pub id: i64,
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
}

#[derive(Clone, Copy, Debug)]
pub struct Point {
    pub t: f64,
    pub pct: f64,
    pub watts: f64,
}

pub struct Snapshot {
    pub live: Option<Sample>,
    pub cycle_count: i64,
    pub design_wh: f64,
    pub state: Option<Value>,
    pub daemon_up: bool,
    pub active: Vec<Point>,
    pub cycles: Vec<Cycle>,
    pub health: Vec<(f64, f64)>,
    pub alarm_enabled: bool,
    pub alarm_target: f64,
    pub stop_threshold: Option<i64>,
    pub abm: Option<i64>,
}

fn state_file() -> std::path::PathBuf {
    let rt = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    std::path::Path::new(&rt).join("accubattery/state.json")
}

pub fn abm_files() -> Vec<std::path::PathBuf> {
    let mut v = Vec::new();
    if let Ok(rd) = std::fs::read_dir("/sys/class/drm") {
        for e in rd.flatten() {
            let p = e.path().join("amdgpu/panel_power_savings");
            if p.exists() {
                v.push(p);
            }
        }
    }
    v
}

fn read_i64(p: &str) -> Option<i64> {
    std::fs::read_to_string(p).ok()?.trim().parse().ok()
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

pub fn snapshot(bat: &Battery) -> Snapshot {
    let live = bat.sample();
    let state: Option<Value> = std::fs::read_to_string(state_file()).ok().and_then(|s| serde_json::from_str(&s).ok());
    let daemon_up = state
        .as_ref()
        .and_then(|s| s["updated"].as_f64())
        .is_some_and(|t| accubattery::battery::now() - t < 40.0);

    let mut snap = Snapshot {
        live,
        cycle_count: bat.cycle_count(),
        design_wh: bat.design_wh(),
        active: Vec::new(),
        cycles: Vec::new(),
        health: Vec::new(),
        alarm_enabled: true,
        alarm_target: 80.0,
        stop_threshold: read_i64("/sys/class/power_supply/BAT0/charge_control_end_threshold"),
        abm: abm_files().first().and_then(|p| read_i64(&p.to_string_lossy())),
        state,
        daemon_up,
    };
    let Ok(db) = Db::open() else { return snap };
    snap.alarm_enabled = db.setting("alarm_enabled").map(|v| !v.eq_ignore_ascii_case("false")).unwrap_or(true);
    snap.alarm_target = db.setting("alarm_target").and_then(|v| v.parse().ok()).unwrap_or(80.0);

    if let Some(id) = snap.state.as_ref().and_then(|s| s["cycle_id"].as_i64()) {
        snap.active = points(&db, id);
    }
    if let Ok(mut st) = db.0.prepare(
        "SELECT id,session_type,kind,start_time,duration_min,start_pct,end_pct,wear_cycles,energy_wh,energy_mah,
                avg_power_w,max_power_w,avg_temp_c,max_temp_c,pd_standard
         FROM cycles WHERE duration_min>0.3 ORDER BY start_time DESC LIMIT 200",
    ) {
        if let Ok(rows) = st.query_map([], |r| {
            Ok(Cycle {
                id: r.get(0)?,
                session: r.get(1)?,
                kind: r.get(2)?,
                start: r.get(3)?,
                duration_min: r.get(4)?,
                start_pct: r.get(5)?,
                end_pct: r.get(6)?,
                wear: r.get(7)?,
                wh: r.get(8)?,
                mah: r.get(9)?,
                avg_w: r.get(10)?,
                max_w: r.get(11)?,
                avg_t: r.get(12)?,
                max_t: r.get(13)?,
                pd: r.get(14)?,
            })
        }) {
            snap.cycles = rows.flatten().collect();
        }
    }
    if let Ok(mut st) = db.0.prepare("SELECT timestamp,health_pct FROM degradation ORDER BY id LIMIT 400") {
        if let Ok(rows) = st.query_map([], |r| Ok((r.get::<_, f64>(0)?, r.get::<_, f64>(1)?))) {
            snap.health = rows.flatten().collect();
        }
    }
    snap
}

pub fn set_setting(key: &str, value: &str) {
    if let Ok(db) = Db::open() {
        let _ = db.0.execute("INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)", [key, value]);
    }
}
