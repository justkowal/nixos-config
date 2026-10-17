//! Charge limit control. TLP owns the thresholds on this system, and modules/battery-schedule.nix
//! already lets the user start battery-charge@travel and battery-charge@default without a prompt,
//! so that is the one path used. Direct sysfs writes are a fallback for machines without it.

use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};

use crate::battery::Battery;
use crate::db::{data_dir, Db};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    /// charge to 100 %
    Travel,
    /// whatever TLP is configured to keep
    Default,
}

impl Mode {
    fn unit(self) -> &'static str {
        match self {
            Mode::Travel => "battery-charge@travel.service",
            Mode::Default => "battery-charge@default.service",
        }
    }
}

pub fn set_mode(bat: &Battery, mode: Mode, db: Option<&Db>) -> Result<(), String> {
    let via_unit = Command::new("timeout")
        .args(["20", "systemctl", "--no-ask-password", "start", mode.unit()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    if via_unit {
        return Ok(());
    }
    let get = |k: &str, d: i64| db.and_then(|d| d.setting(k)).and_then(|v| v.parse().ok()).unwrap_or(d);
    let (start, stop) = match mode {
        Mode::Travel => (0, 100),
        Mode::Default => (get("conserve_start", 75), get("conserve_stop", 80)),
    };
    bat.write_thresholds(start, stop).map_err(|e| format!("no battery-charge unit and sysfs write failed: {e}"))
}

pub fn is_travel(bat: &Battery) -> bool {
    bat.thresholds().0.is_some_and(|s| s >= 99)
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Trip {
    pub started: f64,
    pub until: f64,
    pub scheduled: bool,
}

fn trip_path() -> PathBuf {
    data_dir().join("trip.json")
}

pub fn load_trip() -> Option<Trip> {
    serde_json::from_str(&std::fs::read_to_string(trip_path()).ok()?).ok()
}

pub fn start_trip(bat: &Battery, hours: f64, scheduled: bool, now: f64, db: Option<&Db>) -> Result<Trip, String> {
    set_mode(bat, Mode::Travel, db)?;
    let t = Trip { started: now, until: now + hours * 3600.0, scheduled };
    let _ = std::fs::create_dir_all(data_dir());
    std::fs::write(trip_path(), serde_json::to_string(&t).unwrap_or_default()).map_err(|e| e.to_string())?;
    Ok(t)
}

pub fn end_trip(bat: &Battery, db: Option<&Db>) -> Result<(), String> {
    let r = set_mode(bat, Mode::Default, db);
    let _ = std::fs::remove_file(trip_path());
    r
}

/// Local clock as `date` sees it: weekday 0 = Monday, minutes since midnight, YYYY-MM-DD.
#[derive(Clone, Debug, PartialEq)]
pub struct LocalTime {
    pub dow: u32,
    pub minute: u32,
    pub date: String,
}

pub fn local_time(ts: f64) -> LocalTime {
    let out = Command::new("date")
        .args(["-d", &format!("@{}", ts as i64), "+%u %H %M %F"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let mut it = out.split_whitespace();
    let mut num = || it.next().and_then(|v| v.parse::<u32>().ok()).unwrap_or(0);
    let (dow, h, m) = (num().max(1) - 1, num(), num());
    LocalTime { dow, minute: h * 60 + m, date: it.next().unwrap_or("").to_string() }
}

pub fn parse_hhmm(s: &str) -> Option<u32> {
    let (h, m) = s.trim().split_once(':')?;
    let (h, m): (u32, u32) = (h.parse().ok()?, m.parse().ok()?);
    (h < 24 && m < 60).then_some(h * 60 + m)
}

/// Minutes left in the charge window that ends at the weekly target, if `now` is inside it.
pub fn window_left(now: &LocalTime, target_dow: u32, target_minute: u32, lead_min: u32) -> Option<u32> {
    const WEEK: u32 = 7 * 1440;
    let now_m = now.dow * 1440 + now.minute;
    let target = target_dow * 1440 + target_minute;
    let into = (now_m + WEEK - (target + WEEK - lead_min) % WEEK) % WEEK;
    (into < lead_min).then(|| lead_min - into)
}

pub const DAYS: [&str; 7] = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

pub fn parse_day(s: &str) -> Option<u32> {
    let s = s.to_ascii_lowercase();
    DAYS.iter().position(|d| d.to_ascii_lowercase().starts_with(&s[..s.len().min(3)]) && s.len() >= 3).map(|i| i as u32)
}

#[derive(Debug, PartialEq)]
pub enum Action {
    None,
    End(&'static str),
    Reapply,
    StartScheduled(f64),
}

pub struct Inputs<'a> {
    pub now: f64,
    pub ac: bool,
    pub ac_off_for: f64,
    pub travel_active: bool,
    pub trip: Option<&'a Trip>,
    pub local: &'a LocalTime,
    pub sched: Option<(u32, u32, u32)>,
    pub sched_done_for: Option<&'a str>,
}

/// One decision per poll, kept pure so the schedule and the trip rules are testable.
pub fn decide(i: &Inputs) -> Action {
    if let Some(t) = i.trip {
        if i.now >= t.until {
            return Action::End("timeout");
        }
        if !i.ac && i.ac_off_for >= 60.0 {
            return Action::End("unplugged");
        }
        // the calendar timer sets the default mode every evening and would silently end a trip
        if i.ac && !i.travel_active {
            return Action::Reapply;
        }
        return Action::None;
    }
    if let Some((dow, minute, lead)) = i.sched {
        let key = format!("{}@{}", i.local.date, dow);
        if let Some(left) = window_left(i.local, dow, minute, lead) {
            if i.ac && i.sched_done_for != Some(key.as_str()) {
                // keep full charging allowed until an hour past the target, unplugging ends it earlier
                return Action::StartScheduled(left as f64 / 60.0 + 1.0);
            }
        }
    }
    Action::None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lt(dow: u32, h: u32, m: u32) -> LocalTime {
        LocalTime { dow, minute: h * 60 + m, date: "2026-10-19".into() }
    }

    #[test]
    fn window_wraps_midnight_and_week() {
        // Monday 06:30 target, 3 h lead: opens Monday 03:30
        assert_eq!(window_left(&lt(0, 3, 30), 0, 390, 180), Some(180));
        assert_eq!(window_left(&lt(0, 6, 0), 0, 390, 180), Some(30));
        assert_eq!(window_left(&lt(0, 6, 31), 0, 390, 180), None);
        assert_eq!(window_left(&lt(0, 3, 29), 0, 390, 180), None);
        // Monday 01:00 target with 3 h lead opens Sunday 22:00
        assert_eq!(window_left(&lt(6, 22, 30), 0, 60, 180), Some(150));
    }

    #[test]
    fn trip_ends_on_timeout_or_unplug_and_survives_a_calendar_reset() {
        let local = lt(2, 12, 0);
        let trip = Trip { started: 0.0, until: 1000.0, scheduled: false };
        let base = Inputs { now: 10.0, ac: true, ac_off_for: 0.0, travel_active: true, trip: Some(&trip), local: &local, sched: None, sched_done_for: None };
        assert_eq!(decide(&base), Action::None);
        assert_eq!(decide(&Inputs { now: 1001.0, ..base.clone_with() }), Action::End("timeout"));
        assert_eq!(decide(&Inputs { ac: false, ac_off_for: 90.0, ..base.clone_with() }), Action::End("unplugged"));
        assert_eq!(decide(&Inputs { ac: false, ac_off_for: 20.0, ..base.clone_with() }), Action::None);
        assert_eq!(decide(&Inputs { travel_active: false, ..base.clone_with() }), Action::Reapply);
    }

    #[test]
    fn schedule_starts_once_per_window() {
        let local = lt(0, 4, 0);
        let mk = |done: Option<&'static str>| Inputs { now: 0.0, ac: true, ac_off_for: 0.0, travel_active: false, trip: None, local: &local, sched: Some((0, 390, 180)), sched_done_for: done };
        match decide(&mk(None)) {
            Action::StartScheduled(h) => assert!((h - (150.0 / 60.0 + 1.0)).abs() < 1e-9),
            other => panic!("{other:?}"),
        }
        assert_eq!(decide(&mk(Some("2026-10-19@0"))), Action::None);
    }

    #[test]
    fn day_and_time_parsing() {
        assert_eq!(parse_day("Mon"), Some(0));
        assert_eq!(parse_day("sunday"), Some(6));
        assert_eq!(parse_day("x"), None);
        assert_eq!(parse_hhmm("06:30"), Some(390));
        assert_eq!(parse_hhmm("25:00"), None);
    }

    impl<'a> Inputs<'a> {
        fn clone_with(&self) -> Inputs<'a> {
            Inputs { now: self.now, ac: self.ac, ac_off_for: self.ac_off_for, travel_active: self.travel_active, trip: self.trip, local: self.local, sched: self.sched, sched_done_for: self.sched_done_for }
        }
    }
}
