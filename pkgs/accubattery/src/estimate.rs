//! Predictions shown in the window. Everything here is a guess from past behaviour and is
//! labelled that way in the UI.

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
