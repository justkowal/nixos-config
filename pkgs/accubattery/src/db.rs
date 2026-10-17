use rusqlite::{params, Connection, OptionalExtension, Result};

use crate::engine::{wear, GapCause, Kind, Sample};

pub fn data_dir() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    std::path::Path::new(&home).join(".local/share/accubattery")
}

pub struct Db(pub Connection);

impl Db {
    pub fn open() -> Result<Self> {
        let dir = data_dir();
        let _ = std::fs::create_dir_all(&dir);
        let c = Connection::open(dir.join("history.db"))?;
        c.busy_timeout(std::time::Duration::from_secs(10))?;
        c.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")?;
        let db = Self(c);
        db.init()?;
        Ok(db)
    }

    // same tables the Python GUI reads; kind and gap_s are additive
    fn init(&self) -> Result<()> {
        self.0.execute_batch(
            "CREATE TABLE IF NOT EXISTS cycles (
                id INTEGER PRIMARY KEY AUTOINCREMENT, session_type TEXT NOT NULL,
                start_time REAL NOT NULL, end_time REAL NOT NULL, duration_min REAL NOT NULL,
                start_pct REAL NOT NULL, end_pct REAL NOT NULL, gain_pct REAL NOT NULL,
                wear_cycles REAL NOT NULL, energy_wh REAL NOT NULL, energy_mah REAL NOT NULL,
                avg_power_w REAL NOT NULL, max_power_w REAL NOT NULL, avg_temp_c REAL NOT NULL,
                max_temp_c REAL NOT NULL, min_voltage_v REAL NOT NULL, max_voltage_v REAL NOT NULL,
                pd_standard TEXT, top_apps_json TEXT);
             CREATE TABLE IF NOT EXISTS telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT, cycle_id INTEGER NOT NULL, timestamp REAL NOT NULL,
                capacity_pct REAL NOT NULL, power_w REAL NOT NULL, current_ma REAL NOT NULL,
                voltage_v REAL NOT NULL, temp_c REAL NOT NULL,
                FOREIGN KEY (cycle_id) REFERENCES cycles(id) ON DELETE CASCADE);
             CREATE INDEX IF NOT EXISTS idx_telemetry_cycle ON telemetry(cycle_id);
             CREATE TABLE IF NOT EXISTS degradation (
                id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp REAL NOT NULL, date_str TEXT NOT NULL,
                health_pct REAL NOT NULL, capacity_wh REAL NOT NULL, design_wh REAL NOT NULL,
                cycle_count INTEGER NOT NULL);
             CREATE TABLE IF NOT EXISTS hourly_baseline (
                hour_of_week INTEGER PRIMARY KEY, avg_watts REAL NOT NULL, sample_count INTEGER NOT NULL);
             CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, battery TEXT NOT NULL,
                kind TEXT NOT NULL, detail TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS hourly_draw (
                hour_of_week INTEGER PRIMARY KEY, avg_watts REAL NOT NULL, sample_count INTEGER NOT NULL);
             CREATE TABLE IF NOT EXISTS charge_profile (
                adapter TEXT NOT NULL, band INTEGER NOT NULL, avg_w REAL NOT NULL, n INTEGER NOT NULL,
                PRIMARY KEY (adapter, band));
             CREATE TABLE IF NOT EXISTS habit (
                hour_of_week INTEGER PRIMARY KEY, battery_awake_s REAL NOT NULL DEFAULT 0, battery_asleep_s REAL NOT NULL DEFAULT 0,
                battery_off_s REAL NOT NULL DEFAULT 0, any_awake_s REAL NOT NULL DEFAULT 0, any_away_s REAL NOT NULL DEFAULT 0);
             CREATE TABLE IF NOT EXISTS standby_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, secs REAL NOT NULL, wh REAL NOT NULL, wake_json TEXT);
             CREATE TABLE IF NOT EXISTS daily (
                date_str TEXT PRIMARY KEY, secs_above_90 REAL NOT NULL DEFAULT 0, secs_on_ac REAL NOT NULL DEFAULT 0);",
        )?;
        let have: Vec<String> = self
            .0
            .prepare("SELECT name FROM pragma_table_info('cycles')")?
            .query_map([], |r| r.get(0))?
            .collect::<Result<_>>()?;
        for (name, ddl) in [
            ("kind", "TEXT NOT NULL DEFAULT 'live'"),
            ("gap_s", "REAL NOT NULL DEFAULT 0"),
            ("battery", "TEXT NOT NULL DEFAULT 'BAT0'"),
            ("wake_json", "TEXT"),
        ] {
            if !have.iter().any(|c| c == name) {
                self.0.execute(&format!("ALTER TABLE cycles ADD COLUMN {name} {ddl}"), [])?;
            }
        }
        Ok(())
    }

    pub fn setting(&self, key: &str) -> Option<String> {
        self.0.query_row("SELECT value FROM settings WHERE key=?", [key], |r| r.get(0)).optional().ok().flatten()
    }

    pub fn open_cycle(&self, kind: Kind, at: &Sample, battery: &str) -> Result<i64> {
        self.0.execute(
            "INSERT INTO cycles (session_type,start_time,end_time,duration_min,start_pct,end_pct,gain_pct,wear_cycles,
                energy_wh,energy_mah,avg_power_w,max_power_w,avg_temp_c,max_temp_c,min_voltage_v,max_voltage_v,
                pd_standard,top_apps_json,kind,battery)
             VALUES (?1,?2,?2,0,?3,?3,0,0,0,0,0,0,0,0,0,0,NULL,'[]','live',?4)",
            params![kind.as_str(), at.wall, at.pct, battery],
        )?;
        Ok(self.0.last_insert_rowid())
    }

    pub fn telemetry(&self, id: i64, s: &Sample) -> Result<()> {
        let last: Option<f64> = self
            .0
            .query_row("SELECT MAX(timestamp) FROM telemetry WHERE cycle_id=?", [id], |r| r.get(0))
            .optional()?
            .flatten();
        if last.is_some_and(|t| s.wall - t < 2.0) {
            return Ok(());
        }
        self.0.execute(
            "INSERT INTO telemetry (cycle_id,timestamp,capacity_pct,power_w,current_ma,voltage_v,temp_c) VALUES (?,?,?,?,?,?,?)",
            params![id, s.wall, s.pct, s.watts, s.ma, s.volts, s.temp],
        )?;
        // keep the live row current so a crash loses nothing and the GUI sees progress
        self.0.execute("UPDATE cycles SET end_time=?, end_pct=? WHERE id=?", params![s.wall, s.pct, id])?;
        Ok(())
    }

    /// Closes the cycle, or deletes it when it was just a blip.
    pub fn close_cycle(&self, id: i64, start: &Sample, at: &Sample, pd: Option<&str>) -> Result<()> {
        let dur_s = (at.wall - start.wall).max(0.0);
        let gain = at.pct - start.pct;
        if dur_s < 120.0 && gain.abs() < 1.0 {
            self.0.execute("DELETE FROM cycles WHERE id=?", [id])?;
            return Ok(());
        }
        let (avg_p, max_p, avg_t, max_t, min_v, max_v, avg_v): (f64, f64, f64, f64, f64, f64, f64) = self.0.query_row(
            "SELECT IFNULL(AVG(power_w),0),IFNULL(MAX(power_w),0),IFNULL(AVG(temp_c),0),IFNULL(MAX(temp_c),0),
                    IFNULL(MIN(voltage_v),0),IFNULL(MAX(voltage_v),0),IFNULL(AVG(voltage_v),0)
             FROM telemetry WHERE cycle_id=?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)),
        )?;
        // energy from the gauge delta, not avg power x time, so gaps cannot inflate it
        let wh = (at.wh - start.wh).abs();
        let mah = if avg_v > 0.0 { wh / avg_v * 1000.0 } else { 0.0 };
        self.0.execute(
            "UPDATE cycles SET end_time=?,duration_min=?,end_pct=?,gain_pct=?,wear_cycles=?,energy_wh=?,energy_mah=?,
                avg_power_w=?,max_power_w=?,avg_temp_c=?,max_temp_c=?,min_voltage_v=?,max_voltage_v=?,pd_standard=?
             WHERE id=?",
            params![
                at.wall,
                (dur_s / 60.0 * 10.0).round() / 10.0,
                at.pct,
                (gain * 10.0).round() / 10.0,
                wear(start.pct, at.pct),
                (wh * 100.0).round() / 100.0,
                (mah * 10.0).round() / 10.0,
                avg_p,
                max_p,
                avg_t,
                max_t,
                min_v,
                max_v,
                pd,
                id
            ],
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn offline_cycle(&self, kind: Kind, cause: GapCause, from: &Sample, to: &Sample, est_s: f64, battery: &str, wake: Option<&str>) -> Result<()> {
        let gap = to.wall - from.wall;
        let wh = (to.wh - from.wh).abs();
        let hours = (est_s / 3600.0).max(1e-6);
        let volts = (from.volts + to.volts) / 2.0;
        let label = match (cause, kind) {
            (GapCause::PowerOff, Kind::Charge) => "off_charge",
            (GapCause::PowerOff, Kind::Discharge) => "off_drain",
            (GapCause::Suspend, Kind::Charge) => "sleep_charge",
            (GapCause::Suspend, Kind::Discharge) => "sleep_drain",
        };
        self.0.execute(
            "INSERT INTO cycles (session_type,start_time,end_time,duration_min,start_pct,end_pct,gain_pct,wear_cycles,
                energy_wh,energy_mah,avg_power_w,max_power_w,avg_temp_c,max_temp_c,min_voltage_v,max_voltage_v,
                pd_standard,top_apps_json,kind,gap_s,battery,wake_json)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?, '[]', ?, ?, ?, ?)",
            params![
                kind.as_str(),
                from.wall,
                from.wall + est_s,
                (est_s / 60.0 * 10.0).round() / 10.0,
                from.pct,
                to.pct,
                ((to.pct - from.pct) * 10.0).round() / 10.0,
                wear(from.pct, to.pct),
                (wh * 100.0).round() / 100.0,
                if volts > 0.0 { (wh / volts * 1000.0 * 10.0).round() / 10.0 } else { 0.0 },
                wh / hours,
                wh / hours,
                from.temp,
                from.temp,
                from.volts.min(to.volts),
                from.volts.max(to.volts),
                if kind == Kind::Charge && cause == GapCause::PowerOff { Some("Powered off") } else { None::<&str> },
                label,
                gap,
                battery,
                wake
            ],
        )?;
        Ok(())
    }

    /// false when the row was deleted behind our back
    pub fn open_row(&self, id: i64) -> bool {
        self.0.query_row("SELECT 1 FROM cycles WHERE id=?", [id], |_| Ok(())).is_ok()
    }

    pub fn hourly(&self, hour_of_week: i64, watts: f64) -> Result<()> {
        self.0.execute(
            "INSERT INTO hourly_draw (hour_of_week,avg_watts,sample_count) VALUES (?1,?2,1)
             ON CONFLICT(hour_of_week) DO UPDATE SET
               avg_watts=(avg_watts*sample_count+?2)/(sample_count+1), sample_count=sample_count+1",
            params![hour_of_week, watts],
        )?;
        Ok(())
    }

    pub fn degradation(&self, date: &str, health: f64, cap_wh: f64, design_wh: f64, cycles: i64, ts: f64) -> Result<()> {
        let last: Option<(String, f64)> = self
            .0
            .query_row("SELECT date_str,health_pct FROM degradation ORDER BY id DESC LIMIT 1", [], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?;
        if last.is_some_and(|(d, h)| d == date && (h - health).abs() < 0.2) {
            return Ok(());
        }
        self.0.execute(
            "INSERT INTO degradation (timestamp,date_str,health_pct,capacity_wh,design_wh,cycle_count) VALUES (?,?,?,?,?,?)",
            params![ts, date, (health * 10.0).round() / 10.0, (cap_wh * 100.0).round() / 100.0, (design_wh * 100.0).round() / 100.0, cycles],
        )?;
        Ok(())
    }

    pub fn set_top_apps(&self, id: i64, json: &str) -> Result<()> {
        self.0.execute("UPDATE cycles SET top_apps_json=? WHERE id=?", params![json, id])?;
        Ok(())
    }

    pub fn event(&self, ts: f64, battery: &str, kind: &str, detail: &str) -> Result<()> {
        self.0.execute("INSERT INTO events (ts,battery,kind,detail) VALUES (?,?,?,?)", params![ts, battery, kind, detail])?;
        Ok(())
    }

    pub fn daily_add(&self, date: &str, above_90_s: f64, ac_s: f64) -> Result<()> {
        self.0.execute(
            "INSERT INTO daily (date_str,secs_above_90,secs_on_ac) VALUES (?1,?2,?3)
             ON CONFLICT(date_str) DO UPDATE SET secs_above_90=secs_above_90+?2, secs_on_ac=secs_on_ac+?3",
            params![date, above_90_s, ac_s],
        )?;
        Ok(())
    }

    pub fn profile_load(&self, adapter: &str) -> [f64; 10] {
        let mut p = [0.0; 10];
        if let Ok(mut st) = self.0.prepare("SELECT band,avg_w FROM charge_profile WHERE adapter=? AND n>=5") {
            if let Ok(rows) = st.query_map([adapter], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?))) {
                for (b, w) in rows.flatten() {
                    if (0..10).contains(&b) {
                        p[b as usize] = w;
                    }
                }
            }
        }
        p
    }

    /// running mean per 10 % band, capped at 500 samples so a worn adapter or cell can still move it
    pub fn profile_update(&self, adapter: &str, pct: f64, watts: f64) -> Result<()> {
        let band = ((pct / 10.0).floor() as i64).clamp(0, 9);
        self.0.execute(
            "INSERT INTO charge_profile (adapter,band,avg_w,n) VALUES (?1,?2,?3,1)
             ON CONFLICT(adapter,band) DO UPDATE SET
               avg_w=(avg_w*MIN(n,500)+?3)/(MIN(n,500)+1), n=n+1",
            params![adapter, band, watts],
        )?;
        Ok(())
    }

    /// Closes rows an old crash or the Python logger left open, and drops empty ones.
    /// Rows in `keep` belong to live sessions and are left alone.
    pub fn repair(&self, keep: &[i64], now: f64) -> Result<usize> {
        let ids: Vec<(i64, f64, f64)> = {
            let mut st = self.0.prepare("SELECT id,start_time,start_pct FROM cycles WHERE duration_min=0 AND kind='live'")?;
            let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
            rows.collect::<Result<_>>()?
        };
        let mut fixed = 0;
        for (id, t0, p0) in ids {
            if keep.contains(&id) {
                continue;
            }
            let last: Option<(f64, f64)> = self
                .0
                .query_row("SELECT timestamp,capacity_pct FROM telemetry WHERE cycle_id=? ORDER BY timestamp DESC LIMIT 1", [id], |r| Ok((r.get(0)?, r.get(1)?)))
                .optional()?;
            let Some((t1, p1)) = last else {
                if now - t0 > 3600.0 {
                    self.0.execute("DELETE FROM cycles WHERE id=?", [id])?;
                    fixed += 1;
                }
                continue;
            };
            if t1 - t0 < 120.0 && (p1 - p0).abs() < 1.0 {
                self.0.execute("DELETE FROM cycles WHERE id=?", [id])?;
                fixed += 1;
                continue;
            }
            let (avg_p, max_p, avg_t, max_t, min_v, max_v): (f64, f64, f64, f64, f64, f64) = self.0.query_row(
                "SELECT IFNULL(AVG(power_w),0),IFNULL(MAX(power_w),0),IFNULL(AVG(temp_c),0),IFNULL(MAX(temp_c),0),
                        IFNULL(MIN(voltage_v),0),IFNULL(MAX(voltage_v),0) FROM telemetry WHERE cycle_id=?",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
            )?;
            let hours = (t1 - t0) / 3600.0;
            let wh = avg_p * hours;
            self.0.execute(
                "UPDATE cycles SET end_time=?,duration_min=?,end_pct=?,gain_pct=?,wear_cycles=?,energy_wh=?,energy_mah=?,
                    avg_power_w=?,max_power_w=?,avg_temp_c=?,max_temp_c=?,min_voltage_v=?,max_voltage_v=? WHERE id=?",
                params![
                    t1,
                    (hours * 600.0).round() / 10.0,
                    p1,
                    ((p1 - p0) * 10.0).round() / 10.0,
                    wear(p0, p1),
                    (wh * 100.0).round() / 100.0,
                    if min_v > 0.0 { (wh / min_v.max(11.0) * 10000.0).round() / 10.0 } else { 0.0 },
                    avg_p,
                    max_p,
                    avg_t,
                    max_t,
                    min_v,
                    max_v,
                    id
                ],
            )?;
            fixed += 1;
        }
        Ok(fixed)
    }
}

impl Db {
    /// discharge watts per hour of week, only hours with enough samples to mean something
    pub fn baseline(&self) -> [Option<f64>; 168] {
        let mut b = [None; 168];
        if let Ok(mut st) = self.0.prepare("SELECT hour_of_week,avg_watts FROM hourly_draw WHERE sample_count>=30") {
            if let Ok(rows) = st.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?))) {
                for (h, w) in rows.flatten() {
                    if (0..168).contains(&h) {
                        b[h as usize] = Some(w);
                    }
                }
            }
        }
        b
    }
}

impl Db {
    /// col is one of the habit columns, never user input
    pub fn habit_add(&self, how: usize, col: &str, secs: f64) -> Result<()> {
        let col = match col {
            "battery_awake_s" | "battery_asleep_s" | "battery_off_s" | "any_awake_s" | "any_away_s" => col,
            _ => return Ok(()),
        };
        self.0.execute(
            &format!("INSERT INTO habit (hour_of_week,{col}) VALUES (?1,?2) ON CONFLICT(hour_of_week) DO UPDATE SET {col}={col}+?2"),
            params![how as i64, secs],
        )?;
        Ok(())
    }

    pub fn habit_load(&self) -> crate::estimate::Habit {
        let mut h = crate::estimate::Habit::default();
        if let Ok(mut st) = self.0.prepare("SELECT hour_of_week,battery_awake_s,battery_asleep_s,battery_off_s,any_awake_s,any_away_s FROM habit") {
            if let Ok(rows) = st.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?, r.get::<_, f64>(2)?, r.get::<_, f64>(3)?, r.get::<_, f64>(4)?, r.get::<_, f64>(5)?))) {
                for (how, a, s, o, ua, uy) in rows.flatten() {
                    if (0..168).contains(&how) {
                        let i = how as usize;
                        (h.awake[i], h.asleep[i], h.off[i], h.use_awake[i], h.use_away[i]) = (a, s, o, ua, uy);
                    }
                }
            }
        }
        h
    }

    /// Old weeks fade so a changed timetable takes over: half-life about ten weeks.
    pub fn habit_decay_daily(&self, date: &str) -> Result<()> {
        if self.setting("habit_decay_date").as_deref() == Some(date) {
            return Ok(());
        }
        self.0.execute(
            "UPDATE habit SET battery_awake_s=battery_awake_s*0.99, battery_asleep_s=battery_asleep_s*0.99,
                battery_off_s=battery_off_s*0.99, any_awake_s=any_awake_s*0.99, any_away_s=any_away_s*0.99",
            [],
        )?;
        self.0.execute("INSERT OR REPLACE INTO settings (key,value) VALUES ('habit_decay_date', ?)", [date])?;
        Ok(())
    }

    pub fn standby_log(&self, ts: f64, secs: f64, wh: f64, wake: Option<&str>) -> Result<()> {
        self.0.execute("INSERT INTO standby_log (ts,secs,wh,wake_json) VALUES (?,?,?,?)", params![ts, secs, wh, wake])?;
        Ok(())
    }

    /// measured draw while asleep on battery, 0.5 W until there is data
    pub fn standby_w(&self, now: f64) -> f64 {
        self.0
            .query_row("SELECT SUM(wh),SUM(secs) FROM standby_log WHERE ts>? AND secs>=600", [now - 60.0 * 86400.0], |r| Ok((r.get::<_, Option<f64>>(0)?, r.get::<_, Option<f64>>(1)?)))
            .ok()
            .and_then(|(wh, s)| Some(wh? / (s? / 3600.0)))
            .filter(|w| *w > 0.0 && *w < 10.0)
            .unwrap_or(0.5)
    }

    /// One time: the old telemetry already holds weeks of awake draw per hour of week, so the
    /// daily curve starts from that instead of waiting a month.
    pub fn backfill_draw(&self) -> Result<()> {
        if self.setting("backfill_draw_v1").is_some() {
            return Ok(());
        }
        let mut st = self.0.prepare(
            "SELECT t.timestamp, t.power_w FROM telemetry t JOIN cycles c ON c.id=t.cycle_id
             WHERE c.session_type='discharge' AND t.power_w>0.3 AND t.power_w<200",
        )?;
        let rows: Vec<(f64, f64)> = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_>>()?;
        drop(st);
        let tz = tz_offset_s();
        let mut last_bucket = i64::MIN;
        for (ts, w) in rows {
            // GUI-open sessions sampled every 2 s, keep one sample per 10 s
            let bucket = (ts / 10.0) as i64;
            if bucket == last_bucket {
                continue;
            }
            last_bucket = bucket;
            self.hourly(crate::estimate::local_how(ts, tz) as i64, w)?;
        }
        self.0.execute("INSERT OR REPLACE INTO settings (key,value) VALUES ('backfill_draw_v1','done')", [])?;
        Ok(())
    }
}

/// local offset from UTC in seconds, from `date +%z`
pub fn tz_offset_s() -> f64 {
    let out = std::process::Command::new("date").arg("+%z").output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
    if out.len() < 5 {
        return 0.0;
    }
    let sign = if out.starts_with('-') { -1.0 } else { 1.0 };
    let (h, m): (f64, f64) = (out[1..3].parse().unwrap_or(0.0), out[3..5].parse().unwrap_or(0.0));
    sign * (h * 3600.0 + m * 60.0)
}
