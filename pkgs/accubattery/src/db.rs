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
             CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        )?;
        let have: Vec<String> = self
            .0
            .prepare("SELECT name FROM pragma_table_info('cycles')")?
            .query_map([], |r| r.get(0))?
            .collect::<Result<_>>()?;
        if !have.iter().any(|c| c == "kind") {
            self.0.execute("ALTER TABLE cycles ADD COLUMN kind TEXT NOT NULL DEFAULT 'live'", [])?;
        }
        if !have.iter().any(|c| c == "gap_s") {
            self.0.execute("ALTER TABLE cycles ADD COLUMN gap_s REAL NOT NULL DEFAULT 0", [])?;
        }
        Ok(())
    }

    pub fn setting(&self, key: &str) -> Option<String> {
        self.0.query_row("SELECT value FROM settings WHERE key=?", [key], |r| r.get(0)).optional().ok().flatten()
    }

    pub fn open_cycle(&self, kind: Kind, at: &Sample) -> Result<i64> {
        self.0.execute(
            "INSERT INTO cycles (session_type,start_time,end_time,duration_min,start_pct,end_pct,gain_pct,wear_cycles,
                energy_wh,energy_mah,avg_power_w,max_power_w,avg_temp_c,max_temp_c,min_voltage_v,max_voltage_v,
                pd_standard,top_apps_json,kind)
             VALUES (?1,?2,?2,0,?3,?3,0,0,0,0,0,0,0,0,0,0,NULL,'[]','live')",
            params![kind.as_str(), at.wall, at.pct],
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

    pub fn offline_cycle(&self, kind: Kind, cause: GapCause, from: &Sample, to: &Sample, est_s: f64) -> Result<()> {
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
                pd_standard,top_apps_json,kind,gap_s)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?, '[]', ?, ?)",
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
                gap
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
            "INSERT INTO hourly_baseline (hour_of_week,avg_watts,sample_count) VALUES (?1,?2,1)
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
}
