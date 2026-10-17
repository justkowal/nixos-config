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
}

#[derive(Default, Serialize, Deserialize)]
pub struct Engine {
    pub active: Option<Active>,
    pub prev: Option<Sample>,
    pending: Option<(Option<Kind>, u8, Sample)>,
    /// last healthy charge rate, used to date a charge that happened while we were not running
    pub ref_charge_w: f64,
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
            if s.wall - prev.wall > GAP_S {
                reset = self.handle_gap(&prev, &s, want, &mut out);
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
            let rate = if kind == Kind::Charge {
                if prev.status == Status::Charging && prev.watts > 5.0 { prev.watts } else { self.ref_charge_w }
            } else {
                0.0
            };
            // a charge that topped out finished early; do not stretch it over the whole gap
            let est_s = if rate > 5.0 { (dwh.abs() / rate * 3600.0).min(gap) } else { gap };
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
        e.step(smp(10.0, "a", Status::Idle, 90.0));
        let ev = e.step(smp(20.0, "a", Status::Idle, 90.0));
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
