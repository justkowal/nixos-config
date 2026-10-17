//! Predictions shown in the window. Everything here is a guess from past behaviour and is
//! labelled that way in the UI.

use serde::{Deserialize, Serialize};

use crate::engine::charge_seconds;

pub const HOURS_PER_WEEK: usize = 168;

/// Hours until empty, walking forward hour by hour so a quiet evening after a busy afternoon
/// is priced with the hour-of-week baseline instead of the current draw alone.
/// `recent_w` is the decayed average of this session, `baseline` is discharge watts per hour of week.
pub fn hours_to_empty(wh_now: f64, recent_w: f64, baseline: &[Option<f64>; HOURS_PER_WEEK], start_how: usize) -> Option<f64> {
    if wh_now <= 0.0 || recent_w < 0.3 {
        return None;
    }
    let mut left = wh_now;
    let mut hours = 0.0;
    for i in 0..(24 * 14) {
        let how = (start_how + i) % HOURS_PER_WEEK;
        // trust the live draw for the first hours, drift toward the habit after that
        let w_base = baseline[how].filter(|w| *w > 0.3);
        let mix = match w_base {
            Some(_) => (i as f64 / 6.0).min(1.0) * 0.5,
            None => 0.0,
        };
        let w = recent_w * (1.0 - mix) + w_base.unwrap_or(recent_w) * mix;
        if left <= w {
            return Some(hours + left / w);
        }
        left -= w;
        hours += 1.0;
    }
    None
}

/// EWMA of watts, newest last. alpha 0.15 settles in about 15 samples.
pub fn decayed_watts(samples: &[f64]) -> Option<f64> {
    let mut it = samples.iter().copied().filter(|w| *w > 0.3);
    let mut avg = it.next()?;
    for w in it {
        avg += 0.15 * (w - avg);
    }
    Some(avg)
}

/// Seconds to reach `target` percent while charging. Uses the learned profile, and when a band
/// is unknown scales the live power down above 80 % the way constant-voltage tapering does.
pub fn secs_to_target(profile: &[f64; 10], pct: f64, target: f64, full_wh: f64, live_w: f64) -> Option<f64> {
    let mut p = *profile;
    if live_w > 1.0 {
        for (band, v) in p.iter_mut().enumerate() {
            if *v <= 1.0 {
                *v = if band >= 8 { live_w * 0.5 } else { live_w };
            }
        }
    }
    charge_seconds(&p, pct, target, full_wh, 0.0)
}

/// Least squares line through (t seconds, health %). Returns (percent per day, projected unix time
/// to reach `floor`), None unless the data spans at least `min_days` and has `min_points`.
pub fn project_health(points: &[(f64, f64)], floor: f64, min_days: f64, min_points: usize) -> Option<(f64, f64)> {
    if points.len() < min_points {
        return None;
    }
    let (t0, t1) = (points.first()?.0, points.last()?.0);
    if (t1 - t0) < min_days * 86400.0 {
        return None;
    }
    let n = points.len() as f64;
    let mx = points.iter().map(|p| (p.0 - t0) / 86400.0).sum::<f64>() / n;
    let my = points.iter().map(|p| p.1).sum::<f64>() / n;
    let (mut sxy, mut sxx) = (0.0, 0.0);
    for p in points {
        let dx = (p.0 - t0) / 86400.0 - mx;
        sxy += dx * (p.1 - my);
        sxx += dx * dx;
    }
    if sxx < 1e-9 {
        return None;
    }
    let slope = sxy / sxx;
    if slope >= -1e-4 {
        return None;
    }
    let last_fit = my + slope * ((t1 - t0) / 86400.0 - mx);
    let days = (floor - last_fit) / slope;
    // beyond a decade the straight line is fiction
    (days > 0.0 && days < 3650.0).then_some((slope, t1 + days * 86400.0))
}

/// Share of charges that end in the gentle band and the share of AC time spent above 90 %,
/// folded into one 0..100 score plus one sentence of advice.
pub fn habit(charges_total: usize, charges_in_band: usize, secs_above_90: f64, secs_on_ac: f64) -> Option<(u32, &'static str)> {
    if charges_total < 3 {
        return None;
    }
    let band = charges_in_band as f64 / charges_total as f64;
    let above = if secs_on_ac > 3600.0 { (secs_above_90 / secs_on_ac).min(1.0) } else { 0.0 };
    let score = (100.0 * (0.6 * band + 0.4 * (1.0 - above))).round() as u32;
    let tip = if above > 0.5 {
        "The battery sits above 90 % most of the time on AC. Set the charge limit to Conservation."
    } else if band < 0.5 {
        "Most charges end outside 20 to 80 %. Unplug earlier or set the alarm lower."
    } else {
        "Charging habits are gentle on the battery."
    };
    Some((score, tip))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_with_flat_baseline_is_simple() {
        let b = [None; HOURS_PER_WEEK];
        let h = hours_to_empty(40.0, 10.0, &b, 0).unwrap();
        assert!((h - 4.0).abs() < 1e-6);
    }

    #[test]
    fn busy_hours_ahead_shorten_the_estimate() {
        let mut b = [None; HOURS_PER_WEEK];
        #[allow(clippy::needless_range_loop)]
        for h in 3..HOURS_PER_WEEK {
            b[h] = Some(30.0);
        }
        let quiet = hours_to_empty(40.0, 5.0, &[None; HOURS_PER_WEEK], 0).unwrap();
        let habit = hours_to_empty(40.0, 5.0, &b, 0).unwrap();
        assert!(habit < quiet);
    }

    #[test]
    fn ewma_follows_recent_values() {
        let v: Vec<f64> = (0..20).map(|i| if i < 10 { 5.0 } else { 15.0 }).collect();
        let a = decayed_watts(&v).unwrap();
        assert!(a > 10.0 && a < 15.0);
    }

    #[test]
    fn health_projection_needs_data_and_decline() {
        let day = 86400.0;
        let falling: Vec<(f64, f64)> = (0..40).map(|i| (i as f64 * day, 90.0 - i as f64 * 0.05)).collect();
        let (slope, t) = project_health(&falling, 80.0, 30.0, 8).unwrap();
        assert!((slope + 0.05).abs() < 1e-6);
        // 90 - 39*0.05 = 88.05 now, 8.05 % to go at 0.05 per day
        assert!(((t - 39.0 * day) / day - 161.0).abs() < 1.0);
        assert!(project_health(&falling[..10], 80.0, 30.0, 8).is_none());
        let flat: Vec<(f64, f64)> = (0..40).map(|i| (i as f64 * day, 90.0)).collect();
        assert!(project_health(&flat, 80.0, 30.0, 8).is_none());
    }

    #[test]
    fn habit_tip_follows_the_worst_signal() {
        assert!(habit(2, 2, 0.0, 0.0).is_none());
        let (_, t) = habit(10, 9, 8.0 * 3600.0, 10.0 * 3600.0).unwrap();
        assert!(t.contains("Conservation"));
        let (s, _) = habit(10, 10, 0.0, 10.0 * 3600.0).unwrap();
        assert_eq!(s, 100);
    }
}

/// Hour of week (Monday 00:00 = 0) in local time, given the offset from UTC in seconds.
pub fn local_how(ts: f64, tz_off: f64) -> usize {
    let t = ts + tz_off;
    let day = (t / 86400.0).floor() as i64;
    let dow = (day + 3).rem_euclid(7); // 1970-01-01 was a Thursday
    let hour = ((t.rem_euclid(86400.0)) / 3600.0) as i64;
    (dow * 24 + hour) as usize
}

/// Splits [t0, t1] into per-hour-of-week seconds.
pub fn spread_hours(t0: f64, t1: f64, tz_off: f64) -> Vec<(usize, f64)> {
    let mut out = Vec::new();
    let mut t = t0;
    while t < t1 {
        let local = t + tz_off;
        let next_boundary = t + (3600.0 - local.rem_euclid(3600.0));
        let end = next_boundary.min(t1);
        out.push((local_how(t, tz_off), end - t));
        t = end;
    }
    out
}

/// Seconds observed on battery in each state, per hour of week.
#[derive(Clone)]
pub struct Habit {
    pub awake: [f64; HOURS_PER_WEEK],
    pub asleep: [f64; HOURS_PER_WEEK],
    pub off: [f64; HOURS_PER_WEEK],
    /// on any power source: seconds the laptop was in use and seconds it was asleep or off
    pub use_awake: [f64; HOURS_PER_WEEK],
    pub use_away: [f64; HOURS_PER_WEEK],
}

impl Default for Habit {
    fn default() -> Self {
        Self {
            awake: [0.0; HOURS_PER_WEEK],
            asleep: [0.0; HOURS_PER_WEEK],
            off: [0.0; HOURS_PER_WEEK],
            use_awake: [0.0; HOURS_PER_WEEK],
            use_away: [0.0; HOURS_PER_WEEK],
        }
    }
}

/// An hour needs this much recorded battery time before its mix is trusted.
const MIN_OBSERVED_S: f64 = 1800.0;

impl Habit {
    /// Probability the laptop is in use during this hour of the week, shrunk toward the same
    /// hour on the other days of its group. None when nothing has been observed yet.
    pub fn use_prob(&self, how: usize) -> Option<f64> {
        let hour = how % 24;
        let days = if how / 24 >= 5 { 5..7 } else { 0..5 };
        let pooled = |a: &[f64; HOURS_PER_WEEK]| -> f64 { days.clone().map(|d| a[d * 24 + hour]).sum() };
        let (pu, pa) = (pooled(&self.use_awake), pooled(&self.use_away));
        if pu + pa < MIN_OBSERVED_S {
            return None;
        }
        const K: f64 = 3600.0;
        let prior = pu / (pu + pa);
        let (u, a) = (self.use_awake[how], self.use_away[how]);
        Some((u + K * prior) / (u + a + K))
    }

    /// (awake, asleep, off) fractions for an hour of the week, None when there is too little data.
    /// A sparse hour borrows from the same hour on the other days of its group (weekdays or the
    /// weekend) and from its neighbours, weighted by how much it has seen itself: Bayesian
    /// shrinkage toward the pooled prior, so one odd Tuesday cannot rewrite the forecast.
    pub fn mix(&self, how: usize) -> Option<(f64, f64, f64)> {
        let hour = how % 24;
        let days = if how / 24 >= 5 { 5..7 } else { 0..5 };
        let pooled = |arr: &[f64; HOURS_PER_WEEK]| -> f64 { days.clone().map(|d| arr[d * 24 + hour]).sum() };
        let own = |arr: &[f64; HOURS_PER_WEEK]| -> f64 {
            let prev = (how + HOURS_PER_WEEK - 1) % HOURS_PER_WEEK;
            let next = (how + 1) % HOURS_PER_WEEK;
            arr[how] + 0.3 * (arr[prev] + arr[next])
        };
        let (pa, ps, po) = (pooled(&self.awake), pooled(&self.asleep), pooled(&self.off));
        let ptotal = pa + ps + po;
        if ptotal < MIN_OBSERVED_S {
            return None;
        }
        let (oa, os, oo) = (own(&self.awake), own(&self.asleep), own(&self.off));
        const K: f64 = 3600.0;
        let denom = oa + os + oo + K;
        Some(((oa + K * pa / ptotal) / denom, (os + K * ps / ptotal) / denom, (oo + K * po / ptotal) / denom))
    }
}

#[derive(Default, Debug)]
pub struct Forecast {
    pub points: Vec<(f64, f64)>,
    /// intervals the machine is expected to sleep or be off
    pub sleep: Vec<(f64, f64)>,
    pub end_at: Option<f64>,
    /// pessimistic and optimistic curves (p10 and p90 of the sampled paths)
    pub lo: Vec<(f64, f64)>,
    pub hi: Vec<(f64, f64)>,
    pub end_early: Option<f64>,
    pub end_late: Option<f64>,
    /// false while no hour had enough history, so the curve assumes the laptop stays awake
    pub learned: bool,
}

pub const NF: usize = 8;

/// Online ridge-style regression (recursive least squares with forgetting) of awake battery draw
/// against a smooth daily curve: three harmonics of the 24 h cycle plus a weekend term. It
/// generalises to hours that were never observed, which a plain per-hour average cannot.
#[derive(Clone, Serialize, Deserialize)]
pub struct PowerModel {
    pub w: [f64; NF],
    p: Vec<f64>,
    pub n: u64,
    /// running relative error, used as the spread of the Monte Carlo draw
    pub rel_err: f64,
}

impl Default for PowerModel {
    fn default() -> Self {
        let mut p = vec![0.0; NF * NF];
        for i in 0..NF {
            p[i * NF + i] = 100.0;
        }
        Self { w: [0.0; NF], p, n: 0, rel_err: 0.3 }
    }
}

fn features(how: usize) -> [f64; NF] {
    let h = (how % 24) as f64 + 0.5;
    let weekend = if how / 24 >= 5 { 1.0 } else { 0.0 };
    let a = std::f64::consts::TAU * h / 24.0;
    [1.0, a.sin(), a.cos(), (2.0 * a).sin(), (2.0 * a).cos(), (3.0 * a).sin(), (3.0 * a).cos(), weekend]
}

impl PowerModel {
    const LAMBDA: f64 = 0.9998;

    pub fn update(&mut self, how: usize, watts: f64) {
        if !(0.3..200.0).contains(&watts) {
            return;
        }
        let x = features(how);
        let px: Vec<f64> = (0..NF).map(|i| (0..NF).map(|j| self.p[i * NF + j] * x[j]).sum()).collect();
        let denom = Self::LAMBDA + x.iter().zip(&px).map(|(a, b)| a * b).sum::<f64>();
        let pred: f64 = self.w.iter().zip(&x).map(|(a, b)| a * b).sum();
        let err = watts - pred;
        for i in 0..NF {
            self.w[i] += px[i] / denom * err;
        }
        for i in 0..NF {
            for j in 0..NF {
                self.p[i * NF + j] = (self.p[i * NF + j] - px[i] * px[j] / denom) / Self::LAMBDA;
            }
        }
        self.n += 1;
        if self.n > 20 {
            self.rel_err += 0.02 * (err.abs() / watts.max(1.0) - self.rel_err);
        }
    }

    /// expected awake draw in watts, None until enough samples have been seen
    pub fn predict(&self, how: usize) -> Option<f64> {
        (self.n >= 300).then(|| self.w.iter().zip(features(how)).map(|(a, b)| a * b).sum::<f64>().max(0.5))
    }
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> f64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 11) as f64 / (1u64 << 53) as f64
    }

    fn normal(&mut self) -> f64 {
        let (u, v) = (self.next().max(1e-12), self.next());
        (-2.0 * u.ln()).sqrt() * (std::f64::consts::TAU * v).cos()
    }
}

pub struct DischargeInputs<'a> {
    pub now: f64,
    pub wh: f64,
    pub full_wh: f64,
    pub awake_w: f64,
    pub baseline: &'a [Option<f64>; HOURS_PER_WEEK],
    pub model: Option<&'a PowerModel>,
    pub habit: &'a Habit,
    pub standby_w: f64,
    pub tz_off: f64,
}

const STEP_S: f64 = 300.0;
const HORIZON_S: f64 = 72.0 * 3600.0;
const RUNS: usize = 200;
/// chance per step that a sampled path keeps its current state instead of redrawing it from the hour's mix
const STAY: f64 = 0.97;

/// Monte Carlo over the laptop's day. Every path walks forward in five minute steps, switching
/// between awake, asleep and off according to what this hour of the week usually looks like
/// (sticky, so it sleeps for hours rather than flickering), with an awake draw from the fitted
/// daily curve blended into the live draw and a per-path scale error. The result is the median
/// curve, a p10 to p90 band, the expected sleep periods and the range of empty times.
/// It assumes the charger stays unplugged.
pub fn forecast_discharge(i: &DischargeInputs) -> Forecast {
    let mut f = Forecast::default();
    if i.wh <= 0.0 || i.full_wh <= 0.0 || i.awake_w < 0.3 {
        return f;
    }
    let steps = (HORIZON_S / STEP_S) as usize;
    let sigma = i.model.map_or(0.0, |m| m.rel_err.clamp(0.05, 0.5));
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15 ^ ((i.now / 1800.0) as u64).wrapping_mul(0xD1B5_4A32_D192_ED03) | 1);

    struct Path {
        wh: f64,
        state: u8,
        scale: f64,
        dead_at: Option<f64>,
    }
    let mut paths: Vec<Path> = (0..RUNS).map(|_| Path { wh: i.wh, state: 0, scale: (sigma * rng.normal()).exp(), dead_at: None }).collect();
    let mut rec: Vec<(f64, Vec<f64>)> = Vec::new();
    let mut sleep_start: Option<f64> = None;

    for s in 0..steps {
        let t = i.now + s as f64 * STEP_S;
        let how = local_how(t, i.tz_off);
        let elapsed_h = (t - i.now) / 3600.0;
        let mix = if t - i.now < 600.0 { None } else { i.habit.mix(how) };
        if mix.is_some() {
            f.learned = true;
        }
        let (a, sl, o) = mix.unwrap_or((1.0, 0.0, 0.0));
        let base = i.model.and_then(|m| m.predict(how)).or(i.baseline[how].filter(|w| *w > 0.3)).unwrap_or(i.awake_w);
        let k = (elapsed_h / 4.0).min(1.0) * 0.6;
        let awake_w = i.awake_w * (1.0 - k) + base * k;

        let sleeping = sl + o >= 0.5;
        match (sleeping, sleep_start) {
            (true, None) => sleep_start = Some(t),
            (false, Some(st)) => {
                f.sleep.push((st, t));
                sleep_start = None;
            }
            _ => {}
        }

        for p in paths.iter_mut().filter(|p| p.dead_at.is_none()) {
            if s > 0 && rng.next() > STAY {
                let r = rng.next();
                p.state = if r < a { 0 } else if r < a + sl { 1 } else { 2 };
            }
            let w = match p.state {
                0 => awake_w * p.scale,
                1 => i.standby_w * p.scale,
                _ => 0.0,
            };
            let step_wh = w * STEP_S / 3600.0;
            if step_wh >= p.wh {
                p.dead_at = Some(t + STEP_S * p.wh / step_wh.max(1e-9));
                p.wh = 0.0;
            } else {
                p.wh -= step_wh;
            }
        }
        if s % 3 == 0 {
            rec.push((t, paths.iter().map(|p| p.wh / i.full_wh * 100.0).collect()));
        }
        if paths.iter().all(|p| p.dead_at.is_some()) {
            rec.push((t + STEP_S, vec![0.0; RUNS]));
            break;
        }
    }
    if let Some(st) = sleep_start {
        f.sleep.push((st, i.now + HORIZON_S));
    }

    let q = |v: &mut Vec<f64>, p: f64| {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        v[((v.len() - 1) as f64 * p).round() as usize]
    };
    for (t, mut v) in rec {
        f.lo.push((t, q(&mut v.clone(), 0.1)));
        f.hi.push((t, q(&mut v.clone(), 0.9)));
        f.points.push((t, q(&mut v, 0.5)));
    }
    let mut ends: Vec<f64> = paths.iter().map(|p| p.dead_at.unwrap_or(i.now + HORIZON_S)).collect();
    let horizon_end = i.now + HORIZON_S;
    f.end_early = Some(q(&mut ends.clone(), 0.1)).filter(|t| *t < horizon_end);
    f.end_late = Some(q(&mut ends.clone(), 0.9)).filter(|t| *t < horizon_end);
    f.end_at = Some(q(&mut ends, 0.5)).filter(|t| *t < horizon_end);
    // nothing to show after the pessimistic end is reached: the flat zero tail only stretches the axis
    if let Some(cut) = f.end_late.or(f.end_at) {
        for c in [&mut f.points, &mut f.lo, &mut f.hi] {
            c.retain(|p| p.0 <= cut + STEP_S);
        }
    }
    f
}

pub struct ChargeInputs<'a> {
    pub now: f64,
    pub pct: f64,
    pub full_wh: f64,
    pub live_w: f64,
    pub profile: &'a [f64; 10],
    /// where the hardware stops charging
    pub limit: f64,
}

/// Charge curve from the learned per-band power. Unknown bands use the live power, halved above
/// 80 % where constant-voltage tapering takes over. The curve ends flat at the hardware limit.
pub fn forecast_charge(i: &ChargeInputs) -> Forecast {
    let mut f = Forecast { learned: i.profile.iter().any(|w| *w > 1.0), ..Default::default() };
    let limit = i.limit.clamp(i.pct, 100.0);
    if i.full_wh <= 0.0 || (i.live_w < 1.0 && !f.learned) {
        return f;
    }
    let mut t = i.now;
    let mut pct = i.pct;
    f.points.push((t, pct));
    while pct < limit - 1e-9 {
        let band = ((pct / 10.0).floor() as usize).min(9);
        let w = if i.profile[band] > 1.0 { i.profile[band] } else if band >= 8 { i.live_w * 0.5 } else { i.live_w };
        if w < 1.0 {
            return Forecast { points: Vec::new(), ..f };
        }
        let step = (limit - pct).min(1.0);
        t += step / 100.0 * i.full_wh / w * 3600.0;
        pct += step;
        f.points.push((t, pct));
    }
    f.end_at = Some(t);
    f
}

#[cfg(test)]
mod forecast_tests {
    use super::*;

    const DAY: f64 = 86400.0;

    #[test]
    fn local_hour_of_week_matches_the_calendar() {
        // 2026-10-19 is a Monday, 06:00 UTC at offset 0 is hour 6 of the week
        let monday = 1_792_364_400.0 - 1_792_364_400.0 % DAY; // midnight UTC of that day
        assert_eq!(local_how(monday + 6.0 * 3600.0, 0.0), local_how(monday, 0.0) + 6);
        assert_eq!(local_how(monday + 3600.0, 7200.0), local_how(monday, 0.0) + 3);
        // seven days later is the same hour of week
        assert_eq!(local_how(monday + 7.0 * DAY, 0.0), local_how(monday, 0.0));
    }

    #[test]
    fn spread_hours_adds_up_and_respects_boundaries() {
        let v = spread_hours(1800.0, 1800.0 + 2.0 * 3600.0, 0.0);
        assert_eq!(v.len(), 3);
        assert!((v.iter().map(|x| x.1).sum::<f64>() - 7200.0).abs() < 1e-6);
        assert!((v[0].1 - 1800.0).abs() < 1e-6);
    }

    fn inputs<'a>(habit: &'a Habit, baseline: &'a [Option<f64>; HOURS_PER_WEEK]) -> DischargeInputs<'a> {
        DischargeInputs { now: 0.0, wh: 40.0, full_wh: 50.0, awake_w: 10.0, baseline, model: None, habit, standby_w: 0.5, tz_off: 0.0 }
    }

    #[test]
    fn without_habit_it_assumes_awake_and_says_unlearned() {
        let (h, b) = (Habit::default(), [None; HOURS_PER_WEEK]);
        let f = forecast_discharge(&inputs(&h, &b));
        assert!(!f.learned);
        assert!((f.end_at.unwrap() - 4.0 * 3600.0).abs() < 600.0);
        assert!(f.sleep.is_empty());
    }

    #[test]
    fn habitual_sleep_stretches_the_battery_and_is_marked() {
        // asleep every hour between 01:00 and 08:00 (hours 1..8 of every day), awake otherwise
        let mut h = Habit::default();
        for how in 0..HOURS_PER_WEEK {
            let hour = how % 24;
            if (1..8).contains(&hour) {
                h.asleep[how] = 3600.0;
            } else {
                h.awake[how] = 3600.0;
            }
        }
        let b = [None; HOURS_PER_WEEK];
        let awake_only = forecast_discharge(&inputs(&Habit::default(), &b));
        // start Monday-ish 22:00 so the night is ahead
        let start = 22.0 * 3600.0;
        let f = forecast_discharge(&DischargeInputs { now: start, ..inputs(&h, &b) });
        assert!(f.learned);
        assert!(!f.sleep.is_empty());
        let (a, z) = f.sleep[0];
        assert!(z - a >= 5.0 * 3600.0, "{:?}", f.sleep);
        assert!(f.end_at.unwrap() - start > awake_only.end_at.unwrap());
    }

    #[test]
    fn charge_curve_tapers_and_stops_at_the_limit() {
        let p = [0.0; 10];
        let f = forecast_charge(&ChargeInputs { now: 0.0, pct: 50.0, full_wh: 50.0, live_w: 25.0, profile: &p, limit: 100.0 });
        let t80 = f.points.iter().find(|p| p.1 >= 80.0).unwrap().0;
        let t100 = f.points.last().unwrap().0;
        // 30 % at 25 W is 0.6 h, the last 20 % at half power is 0.8 h
        assert!((t80 - 0.6 * 3600.0).abs() < 60.0);
        assert!((t100 - t80 - 0.8 * 3600.0).abs() < 60.0);
        let capped = forecast_charge(&ChargeInputs { now: 0.0, pct: 50.0, full_wh: 50.0, live_w: 25.0, profile: &p, limit: 80.0 });
        assert!((capped.points.last().unwrap().1 - 80.0).abs() < 1e-6);
    }
}

#[cfg(test)]
mod learning_tests {
    use super::*;

    #[test]
    fn power_model_learns_an_unseen_hour_from_a_smooth_day() {
        let truth = |how: usize| {
            let h = (how % 24) as f64;
            6.0 + 4.0 * (std::f64::consts::TAU * (h - 14.0) / 24.0).cos().max(0.0)
        };
        let mut m = PowerModel::default();
        for round in 0..30 {
            for how in 0..HOURS_PER_WEEK {
                if how % 24 == 11 || how % 24 == 15 {
                    continue;
                }
                m.update(how, truth(how) + if round % 2 == 0 { 0.2 } else { -0.2 });
            }
        }
        for how in [11usize, 15, 35, 15 + 24 * 3] {
            let p = m.predict(how).unwrap();
            assert!((p - truth(how)).abs() < 1.5, "hour {how}: {p} vs {}", truth(how));
        }
    }

    #[test]
    fn sparse_hours_borrow_from_their_day_group() {
        let mut h = Habit::default();
        for d in [0usize, 2, 3, 4] {
            h.asleep[d * 24 + 3] = 3600.0 * 4.0;
        }
        h.awake[24 + 3] = 300.0;
        let (a, s, _) = h.mix(24 + 3).unwrap();
        assert!(s > 0.8 && a < 0.2, "{a} {s}");
        assert!(h.mix(5 * 24 + 3).is_none());
    }

    #[test]
    fn band_widens_with_uncertainty_and_is_stable() {
        let (h, b) = (Habit::default(), [None; HOURS_PER_WEEK]);
        let mut m = PowerModel::default();
        m.n = 1000;
        m.rel_err = 0.3;
        let run = || {
            forecast_discharge(&DischargeInputs { now: 0.0, wh: 40.0, full_wh: 50.0, awake_w: 10.0, baseline: &b, model: Some(&m), habit: &h, standby_w: 0.5, tz_off: 0.0 })
        };
        let f = run();
        let (e, med, l) = (f.end_early.unwrap(), f.end_at.unwrap(), f.end_late.unwrap());
        assert!(e < med && med < l, "{e} {med} {l}");
        let mid = f.points.len() / 2;
        assert!(f.lo[mid].1 <= f.points[mid].1 && f.points[mid].1 <= f.hi[mid].1);
        assert_eq!(f.end_at, run().end_at);
    }
}

#[cfg(test)]
mod use_tests {
    use super::*;

    #[test]
    fn use_probability_follows_the_schedule() {
        let mut h = Habit::default();
        for d in 0..5 {
            h.use_awake[d * 24 + 10] = 3600.0 * 3.0;
            h.use_away[d * 24 + 3] = 3600.0 * 3.0;
        }
        assert!(h.use_prob(10).unwrap() > 0.9);
        assert!(h.use_prob(24 * 2 + 3).unwrap() < 0.1);
        assert!(h.use_prob(24 * 6 + 10).is_none());
    }
}
