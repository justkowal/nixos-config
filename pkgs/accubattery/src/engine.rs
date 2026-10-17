//! Pure session state machine. No I/O, so the awkward cases (suspend, power off,
//! charge limit holds, status flapping) are unit tested.

use serde::{Deserialize, Serialize};

/// polls are 10 s apart; anything longer than this means the machine was not running us
pub const GAP_S: f64 = 60.0;
const DEBOUNCE: u8 = 2;
/// minimum energy move across a gap, as a fraction of full capacity, to count as a session
const GAP_MIN_FRAC: f64 = 0.005;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Status {
    Charging,
    Discharging,
    /// Full, Not charging (charge limit hold) or Unknown with nothing flowing
    Idle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Kind {
    Charge,
    Discharge,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Charge => "charge",
            Kind::Discharge => "discharge",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Sample {
    pub wall: f64,
    pub boot_id: String,
    pub status: Status,
    pub ac: bool,
    pub pct: f64,
    pub wh: f64,
    pub full_wh: f64,
    pub watts: f64,
    pub volts: f64,
    pub ma: f64,
    pub temp: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Active {
    pub kind: Kind,
    pub start: Sample,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GapCause {
    Suspend,
    PowerOff,
}

#[derive(Debug)]
pub enum Event {
    Open { kind: Kind, at: Sample },
    Telemetry(Sample),
    Close { start: Sample, kind: Kind, at: Sample },
    /// session reconstructed from the energy delta across a gap
    Offline { kind: Kind, cause: GapCause, from: Sample, to: Sample, est_s: f64 },
    /// the gauge moved in a way no load can explain (relearn, firmware reset); no session is logged
    Glitch { reason: &'static str, from: Sample, to: Sample },
}

#[derive(Default, Serialize, Deserialize)]
pub struct Engine {
    pub active: Option<Active>,
    pub prev: Option<Sample>,
    pending: Option<(Option<Kind>, u8, Sample)>,
    /// last healthy charge rate, used to date a charge that happened while we were not running
    pub ref_charge_w: f64,
    /// learned charge power in W for each 10 % band of the battery, 0 when unknown
    #[serde(default)]
    pub profile: [f64; 10],
}

impl Sample {
    pub const CSV_HEADER: &'static str = "wall,boot_id,status,ac,pct,wh,full_wh,watts,volts,ma,temp";

    pub fn to_csv(&self) -> String {
        let st = match self.status {
            Status::Charging => 'C',
            Status::Discharging => 'D',
            Status::Idle => 'I',
        };
        format!(
            "{:.1},{},{},{},{:.4},{:.4},{:.4},{:.3},{:.3},{:.1},{:.1}",
            self.wall, self.boot_id, st, self.ac as u8, self.pct, self.wh, self.full_wh, self.watts, self.volts, self.ma, self.temp
        )
    }

    pub fn from_csv(line: &str) -> Option<Sample> {
        let f: Vec<&str> = line.trim().split(',').collect();
        if f.len() != 11 {
            return None;
        }
        let n = |i: usize| f[i].parse::<f64>().ok();
        Some(Sample {
            wall: n(0)?,
            boot_id: f[1].to_string(),
            status: match f[2] {
                "C" => Status::Charging,
                "D" => Status::Discharging,
                "I" => Status::Idle,
                _ => return None,
            },
            ac: f[3] == "1",
            pct: n(4)?,
            wh: n(5)?,
            full_wh: n(6)?,
            watts: n(7)?,
            volts: n(8)?,
            ma: n(9)?,
            temp: n(10)?,
        })
    }
}

/// Seconds to charge the battery from `from` to `to` percent using the learned band powers.
/// Bands without data fall back to `fallback_w`; None when nothing is known at all.
pub fn charge_seconds(profile: &[f64; 10], from: f64, to: f64, full_wh: f64, fallback_w: f64) -> Option<f64> {
    if to <= from || full_wh <= 0.0 {
        return Some(0.0);
    }
    let mut secs = 0.0;
    #[allow(clippy::needless_range_loop)]
    for band in 0..10 {
        let (lo, hi) = (band as f64 * 10.0, band as f64 * 10.0 + 10.0);
        let span = to.min(hi) - from.max(lo);
        if span <= 0.0 {
            continue;
        }
        let w = if profile[band] > 1.0 { profile[band] } else { fallback_w };
        if w < 1.0 {
            return None;
        }
        secs += span / 100.0 * full_wh / w * 3600.0;
    }
    Some(secs)
}

fn kind_of(s: &Sample) -> Option<Kind> {
    match s.status {
        Status::Charging => Some(Kind::Charge),
        Status::Discharging => Some(Kind::Discharge),
        Status::Idle => None,
    }
}

impl Engine {
    pub fn step(&mut self, s: Sample) -> Vec<Event> {
        let mut out = Vec::new();
        if s.status == Status::Charging && s.watts > 5.0 {
            self.ref_charge_w = s.watts;
        }
        let want = kind_of(&s);

        let mut reset = false;
        if let Some(prev) = self.prev.clone() {
            let dt = s.wall - prev.wall;
            if dt > GAP_S {
                reset = self.handle_gap(&prev, &s, want, &mut out);
            } else if dt > 0.0 {
                // a load of 100 W for 30 s moves 0.8 Wh; anything far past that is the gauge, not the battery
                let expected = prev.watts.max(s.watts) * dt / 3600.0;
                if (s.wh - prev.wh).abs() > (expected * 10.0 + 0.3).max(1.0) {
                    out.push(Event::Glitch { reason: "energy jump", from: prev.clone(), to: s.clone() });
                    self.close(&prev, &mut out);
                    self.pending = None;
                    reset = true;
                } else if prev.full_wh > 0.0 && (s.full_wh - prev.full_wh).abs() / prev.full_wh > 0.04 {
                    out.push(Event::Glitch { reason: "capacity relearn", from: prev.clone(), to: s.clone() });
                }
            }
        }

        let cur = self.active.as_ref().map(|a| a.kind);
        if (self.prev.is_none() || reset) && self.active.is_none() {
            if let Some(k) = want {
                self.open(k, &s, &mut out);
            }
        } else if want != cur {
            let (_, n, first) = match self.pending.take() {
                Some((k, n, f)) if k == want => (k, n + 1, f),
                _ => (want, 1, s.clone()),
            };
            if n >= DEBOUNCE {
                // the change really started at the first sample that showed it
                self.close(&first, &mut out);
                if let Some(k) = want {
                    self.open(k, &first, &mut out);
                }
            } else {
                self.pending = Some((want, n, first));
            }
        } else {
            self.pending = None;
        }

        if self.active.is_some() {
            out.push(Event::Telemetry(s.clone()));
        }
        self.prev = Some(s);
        out
    }

    /// true when the active session was closed and the stream starts fresh
    fn handle_gap(&mut self, prev: &Sample, s: &Sample, want: Option<Kind>, out: &mut Vec<Event>) -> bool {
        let cause = if prev.boot_id == s.boot_id { GapCause::Suspend } else { GapCause::PowerOff };
        let dwh = s.wh - prev.wh;
        let thr = GAP_MIN_FRAC * s.full_wh.max(prev.full_wh);

        let continues = cause == GapCause::Suspend
            && self.active.as_ref().is_some_and(|a| {
                Some(a.kind) == want
                    && match a.kind {
                        Kind::Charge => dwh >= -thr,
                        Kind::Discharge => dwh <= thr,
                    }
            });
        if continues {
            return false;
        }

        self.close(prev, out);
        self.pending = None;
        if dwh.abs() >= thr {
            let kind = if dwh > 0.0 { Kind::Charge } else { Kind::Discharge };
            let gap = s.wall - prev.wall;
            let fallback = if prev.status == Status::Charging && prev.watts > 5.0 { prev.watts } else { self.ref_charge_w };
            // a charge that topped out finished early; do not stretch it over the whole gap
            let est_s = match kind {
                Kind::Charge => charge_seconds(&self.profile, prev.pct, s.pct, s.full_wh.max(prev.full_wh), fallback)
                    .map_or(gap, |t| t.min(gap)),
                Kind::Discharge => gap,
            };
            out.push(Event::Offline { kind, cause, from: prev.clone(), to: s.clone(), est_s });
        }
        true
    }

    fn open(&mut self, kind: Kind, at: &Sample, out: &mut Vec<Event>) {
        self.active = Some(Active { kind, start: at.clone() });
        out.push(Event::Open { kind, at: at.clone() });
    }

    fn close(&mut self, at: &Sample, out: &mut Vec<Event>) {
        if let Some(a) = self.active.take() {
            out.push(Event::Close { start: a.start, kind: a.kind, at: at.clone() });
        }
    }
}

/// Li-ion stress model: share of one full cycle of wear for going from `a` to `b` percent
pub fn wear(a: f64, b: f64) -> f64 {
    if b <= a {
        return 0.0;
    }
    let r = |p: f64| (p / 100.0).clamp(0.0, 1.0).powf(3.5);
    ((r(b) - r(a)) * 1000.0).round().max(10.0) / 1000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn smp(wall: f64, boot: &str, st: Status, pct: f64) -> Sample {
        Sample {
            wall,
            boot_id: boot.into(),
            status: st,
            ac: st != Status::Discharging,
            pct,
            wh: pct * 0.5,
            full_wh: 50.0,
            watts: if st == Status::Charging { 30.0 } else { 8.0 },
            volts: 12.0,
            ma: 1000.0,
            temp: 30.0,
        }
    }

    fn kinds(ev: &[Event]) -> Vec<&'static str> {
        ev.iter()
            .map(|e| match e {
                Event::Open { .. } => "open",
                Event::Telemetry(_) => "tel",
                Event::Close { .. } => "close",
                Event::Offline { .. } => "offline",
                Event::Glitch { .. } => "glitch",
            })
            .collect()
    }

    #[test]
    fn flapping_status_is_debounced() {
        let mut e = Engine::default();
        e.step(smp(0.0, "a", Status::Charging, 50.0));
        let ev = e.step(smp(10.0, "a", Status::Discharging, 50.0));
        assert_eq!(kinds(&ev), ["tel"]);
        let ev = e.step(smp(20.0, "a", Status::Charging, 50.0));
        assert_eq!(kinds(&ev), ["tel"]);
        assert_eq!(e.active.as_ref().unwrap().kind, Kind::Charge);
    }

    #[test]
    fn charge_limit_hold_closes_session() {
        let mut e = Engine::default();
        e.step(smp(0.0, "a", Status::Charging, 80.0));
        e.step(smp(10.0, "a", Status::Idle, 80.1));
        let ev = e.step(smp(20.0, "a", Status::Idle, 80.1));
        assert_eq!(kinds(&ev), ["close"]);
        assert!(e.active.is_none());
    }

    #[test]
    fn charge_while_powered_off_is_reconstructed() {
        let mut e = Engine { ref_charge_w: 30.0, ..Default::default() };
        e.step(smp(0.0, "a", Status::Discharging, 20.0));
        let ev = e.step(smp(7200.0, "b", Status::Discharging, 95.0));
        assert!(kinds(&ev).contains(&"offline"));
        let off = ev.iter().find_map(|e| match e {
            Event::Offline { kind, cause, est_s, .. } => Some((*kind, *cause, *est_s)),
            _ => None,
        });
        let (k, c, est) = off.unwrap();
        assert_eq!((k, c), (Kind::Charge, GapCause::PowerOff));
        assert!(est < 7200.0);
    }

    #[test]
    fn suspend_with_same_direction_continues() {
        let mut e = Engine::default();
        e.step(smp(0.0, "a", Status::Discharging, 80.0));
        let ev = e.step(smp(3600.0, "a", Status::Discharging, 78.0));
        assert_eq!(kinds(&ev), ["tel"]);
    }

    #[test]
    fn suspend_drain_then_plug_in_splits() {
        let mut e = Engine::default();
        e.step(smp(0.0, "a", Status::Discharging, 80.0));
        let ev = e.step(smp(36000.0, "a", Status::Charging, 70.0));
        assert_eq!(kinds(&ev), ["close", "offline", "open", "tel"]);
    }

    #[test]
    fn wear_matches_old_formula() {
        assert!((wear(0.0, 100.0) - 1.0).abs() < 1e-9);
        assert!((wear(0.0, 80.0) - 0.458).abs() < 0.01);
    }
}

#[cfg(test)]
mod more_tests {
    use super::*;

    fn smp(wall: f64, st: Status, pct: f64, wh: f64) -> Sample {
        Sample {
            wall,
            boot_id: "a".into(),
            status: st,
            ac: st != Status::Discharging,
            pct,
            wh,
            full_wh: 50.0,
            watts: 10.0,
            volts: 12.0,
            ma: 800.0,
            temp: 0.0,
        }
    }

    #[test]
    fn energy_jump_is_a_glitch_not_a_session() {
        let mut e = Engine::default();
        e.step(smp(0.0, Status::Discharging, 60.0, 30.0));
        let ev = e.step(smp(10.0, Status::Discharging, 40.0, 20.0));
        assert!(ev.iter().any(|x| matches!(x, Event::Glitch { .. })));
        assert!(!ev.iter().any(|x| matches!(x, Event::Offline { .. })));
    }

    #[test]
    fn csv_roundtrip() {
        let s = smp(1234.5, Status::Charging, 55.5, 27.75);
        let back = Sample::from_csv(&s.to_csv()).unwrap();
        assert_eq!(back.status, Status::Charging);
        assert!((back.pct - 55.5).abs() < 1e-3);
        assert!(Sample::from_csv("junk").is_none());
    }

    #[test]
    fn profile_dates_a_taper() {
        let mut p = [0.0; 10];
        p.iter_mut().for_each(|v| *v = 40.0);
        p[9] = 10.0;
        let fast = charge_seconds(&p, 0.0, 80.0, 50.0, 0.0).unwrap();
        let slow = charge_seconds(&p, 90.0, 100.0, 50.0, 0.0).unwrap();
        // 40 Wh at 40 W is an hour, 5 Wh at 10 W is half an hour
        assert!((fast - 3600.0).abs() < 1.0);
        assert!((slow - 1800.0).abs() < 1.0);
        assert!(charge_seconds(&[0.0; 10], 0.0, 50.0, 50.0, 0.0).is_none());
    }
}

/// One line per event, stable enough to assert on in replay tests.
pub fn describe(e: &Event) -> String {
    match e {
        Event::Open { kind, at } => format!("open {} at {:.0}% t={:.0}", kind.as_str(), at.pct, at.wall),
        Event::Telemetry(_) => "tel".into(),
        Event::Close { kind, at, start } => format!("close {} {:.0}%->{:.0}%", kind.as_str(), start.pct, at.pct),
        Event::Offline { kind, cause, from, to, .. } => {
            format!("offline {} {:?} {:.0}%->{:.0}%", kind.as_str(), cause, from.pct, to.pct)
        }
        Event::Glitch { reason, .. } => format!("glitch {reason}"),
    }
}
