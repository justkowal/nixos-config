//! Calendar-aware reminders: when an event falls in hours the laptop is usually in use and the
//! battery will not last it, say so early enough to charge. Events come from
//! `accubattery-events` (evolution-data-server, same calendars as the travel check).

use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Deserialize;

use crate::engine::charge_seconds;
use crate::estimate::{forecast_charge, forecast_discharge, local_how, ChargeInputs, DischargeInputs, Habit, PowerModel, HOURS_PER_WEEK};

#[derive(Clone, Debug, Deserialize)]
pub struct Ev {
    pub uid: String,
    pub title: String,
    pub start: f64,
    pub end: f64,
    #[serde(default)]
    pub all_day: bool,
}

pub fn parse(json: &str) -> Vec<Ev> {
    serde_json::from_str(json).unwrap_or_default()
}

/// Refreshes the event list off the main loop: the calendar call can take seconds.
pub fn spawn_refresher(shared: Arc<Mutex<Vec<Ev>>>) {
    std::thread::spawn(move || loop {
        let out = Command::new("timeout")
            .args(["30", "accubattery-events", "36"])
            .stderr(Stdio::null())
            .output();
        if let Ok(o) = out {
            if o.status.success() {
                if let Ok(mut g) = shared.lock() {
                    *g = parse(&String::from_utf8_lossy(&o.stdout));
                }
            }
        }
        std::thread::sleep(Duration::from_secs(600));
    });
}

pub struct Ctx<'a> {
    pub now: f64,
    pub pct: f64,
    pub full_wh: f64,
    pub ac: bool,
    /// where the hardware stops charging, 100 when unrestricted
    pub limit: f64,
    pub awake_w: f64,
    pub model: Option<&'a PowerModel>,
    pub baseline: &'a [Option<f64>; HOURS_PER_WEEK],
    pub habit: &'a Habit,
    pub profile: &'a [f64; 10],
    pub live_charge_w: f64,
    pub standby_w: f64,
    pub tz_off: f64,
    /// only remind for events in hours the laptop is in use at least this often
    pub min_use: f64,
    pub reserve_pct: f64,
}

#[derive(Debug, PartialEq)]
pub enum Kind {
    /// on battery and short: plug in
    PlugIn,
    /// on AC but the charge limit stops short of what the event needs
    RaiseLimit { limit: f64 },
}

#[derive(Debug)]
pub struct Reminder {
    pub kind: Kind,
    /// minutes of the event the battery would not cover
    pub short_min: f64,
    /// unix time to remind at: late enough not to nag, early enough to charge the shortfall
    pub due: f64,
}

fn pct_at(points: &[(f64, f64)], t: f64) -> Option<f64> {
    let w = points.windows(2).find(|w| w[0].0 <= t && t <= w[1].0)?;
    let f = (t - w[0].0) / (w[1].0 - w[0].0).max(1e-9);
    Some(w[0].1 + f * (w[1].1 - w[0].1))
}

/// Decides whether an event needs a reminder. Pure, so the rules are testable.
pub fn check(ev: &Ev, c: &Ctx) -> Option<Reminder> {
    if ev.all_day || ev.end <= c.now || ev.start > c.now + 12.0 * 3600.0 {
        return None;
    }
    let start = ev.start.max(c.now);
    let hours: Vec<usize> = crate::estimate::spread_hours(start, ev.end, c.tz_off).into_iter().map(|h| h.0).collect();
    let uses: Vec<f64> = hours.iter().filter_map(|h| c.habit.use_prob(*h)).collect();
    // no history yet counts as "might use it": a wrong reminder is cheaper than a dead laptop
    if !uses.is_empty() && uses.iter().sum::<f64>() / (uses.len() as f64) < c.min_use {
        return None;
    }

    let wh_now = c.pct / 100.0 * c.full_wh;
    // battery when the event starts
    let pct_start = if start <= c.now {
        c.pct
    } else if c.ac {
        let f = forecast_charge(&ChargeInputs { now: c.now, pct: c.pct, full_wh: c.full_wh, live_w: c.live_charge_w, profile: c.profile, limit: c.limit });
        if f.points.is_empty() {
            c.pct
        } else {
            pct_at(&f.points, start).unwrap_or_else(|| f.points.last().map_or(c.pct, |p| p.1))
        }
    } else {
        let f = forecast_discharge(&DischargeInputs {
            now: c.now,
            wh: wh_now,
            full_wh: c.full_wh,
            awake_w: c.awake_w,
            baseline: c.baseline,
            model: c.model,
            habit: c.habit,
            standby_w: c.standby_w,
            tz_off: c.tz_off,
        });
        // pessimistic curve: the reminder is for the bad day
        pct_at(&f.lo, start).unwrap_or(0.0)
    };

    let how = local_how(start, c.tz_off);
    let draw = c.model.and_then(|m| m.predict(how)).map_or(c.awake_w, |m| 0.5 * m + 0.5 * c.awake_w).max(1.0);
    let duration_h = (ev.end - start) / 3600.0;
    let need_wh = draw * duration_h * 1.15;
    let have_wh = ((pct_start - c.reserve_pct) / 100.0 * c.full_wh).max(0.0);
    if have_wh >= need_wh {
        return None;
    }
    let short_min = (need_wh - have_wh) / draw * 60.0;

    let needed_pct = (c.reserve_pct + need_wh / c.full_wh * 100.0).min(100.0);
    if c.ac {
        // plugged in already: only the limit can be the problem
        return (c.limit < needed_pct - 1.0).then_some(Reminder { kind: Kind::RaiseLimit { limit: c.limit }, short_min, due: c.now });
    }
    let charge_s = charge_seconds(c.profile, pct_start.max(c.pct.min(pct_start)), needed_pct, c.full_wh, c.live_charge_w.max(20.0)).unwrap_or(3600.0);
    Some(Reminder { kind: Kind::PlugIn, short_min, due: ev.start - charge_s - 20.0 * 60.0 })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx<'a>(habit: &'a Habit, baseline: &'a [Option<f64>; HOURS_PER_WEEK], profile: &'a [f64; 10]) -> Ctx<'a> {
        Ctx {
            now: 0.0,
            pct: 30.0,
            full_wh: 50.0,
            ac: false,
            limit: 100.0,
            awake_w: 10.0,
            model: None,
            baseline,
            habit,
            profile,
            live_charge_w: 30.0,
            standby_w: 0.5,
            tz_off: 0.0,
            min_use: 0.35,
            reserve_pct: 10.0,
        }
    }

    fn ev(start_h: f64, len_h: f64) -> Ev {
        Ev { uid: "x".into(), title: "Lecture".into(), start: start_h * 3600.0, end: (start_h + len_h) * 3600.0, all_day: false }
    }

    #[test]
    fn short_battery_gets_a_plug_in_reminder_due_before_the_event() {
        let (h, b, p) = (Habit::default(), [None; HOURS_PER_WEEK], [0.0; 10]);
        // 30 % of 50 Wh is 15 Wh, 10 % reserve leaves 10 Wh, a 3 h lecture at 10 W needs 34.5 Wh
        let r = check(&ev(1.0, 3.0), &ctx(&h, &b, &p)).unwrap();
        assert_eq!(r.kind, Kind::PlugIn);
        assert!(r.short_min > 60.0);
        assert!(r.due < 3600.0, "due {}", r.due);
    }

    #[test]
    fn enough_battery_or_all_day_events_are_quiet() {
        let (h, b, p) = (Habit::default(), [None; HOURS_PER_WEEK], [0.0; 10]);
        let mut c = ctx(&h, &b, &p);
        c.pct = 95.0;
        assert!(check(&ev(1.0, 1.0), &c).is_none());
        let mut all_day = ev(1.0, 20.0);
        all_day.all_day = true;
        assert!(check(&all_day, &ctx(&h, &b, &p)).is_none());
    }

    #[test]
    fn hours_the_laptop_is_never_used_are_skipped() {
        let (mut h, b, p) = (Habit::default(), [None; HOURS_PER_WEEK], [0.0; 10]);
        for how in 0..HOURS_PER_WEEK {
            h.use_away[how] = 3600.0 * 5.0;
        }
        assert!(check(&ev(1.0, 3.0), &ctx(&h, &b, &p)).is_none());
    }

    #[test]
    fn plugged_in_but_limited_asks_to_raise_the_limit() {
        let (h, b, p) = (Habit::default(), [None; HOURS_PER_WEEK], [0.0; 10]);
        let mut c = ctx(&h, &b, &p);
        c.ac = true;
        c.pct = 80.0;
        c.limit = 80.0;
        let r = check(&ev(1.0, 4.0), &c).unwrap();
        assert_eq!(r.kind, Kind::RaiseLimit { limit: 80.0 });
        c.limit = 100.0;
        assert!(check(&ev(1.0, 4.0), &c).is_none());
    }
}
