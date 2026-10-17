//! Who spent the battery: CPU time and GPU engine time per program, attributed to the
//! measured system draw while discharging. It is an estimate and the UI says so.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;

use serde::{Deserialize, Serialize};

const CLK_TCK: f64 = 100.0;
const GPU_WEIGHT: f64 = 1.5;

#[derive(Default, Serialize, Deserialize)]
pub struct Apps {
    pub wh: BTreeMap<String, f64>,
    #[serde(skip)]
    prev: HashMap<u32, (f64, f64)>,
}

fn clean(name: &str) -> String {
    let n = name.trim_start_matches('.').trim_end_matches("-wrapped");
    n.trim_end_matches('_').to_string()
}

fn proc_name(pid: u32) -> String {
    let base = format!("/proc/{pid}");
    if let Ok(exe) = fs::read_link(format!("{base}/exe")) {
        if let Some(n) = exe.file_name() {
            return clean(&n.to_string_lossy());
        }
    }
    if fs::read(format!("{base}/cmdline")).map(|c| c.is_empty()).unwrap_or(true) {
        return "kernel".into();
    }
    fs::read_to_string(format!("{base}/comm")).map(|s| clean(s.trim())).unwrap_or_else(|_| "unknown".into())
}

fn cpu_ticks(pid: u32) -> Option<f64> {
    let s = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rest = &s[s.rfind(')')? + 2..];
    let f: Vec<&str> = rest.split_whitespace().collect();
    Some(f.get(11)?.parse::<f64>().ok()? + f.get(12)?.parse::<f64>().ok()?)
}

/// total engine busy time in ns over this process's distinct drm clients
fn gpu_ns(pid: u32) -> f64 {
    let Ok(rd) = fs::read_dir(format!("/proc/{pid}/fdinfo")) else { return 0.0 };
    let mut seen = HashSet::new();
    let mut total = 0.0;
    for e in rd.flatten() {
        let Ok(text) = fs::read_to_string(e.path()) else { continue };
        if !text.contains("drm-driver:") {
            continue;
        }
        let id = text.lines().find_map(|l| l.strip_prefix("drm-client-id:")).map(|v| v.trim().to_string());
        if id.as_ref().is_some_and(|i| !seen.insert(i.clone())) {
            continue;
        }
        for l in text.lines() {
            if let Some(rest) = l.strip_prefix("drm-engine-") {
                if let Some((_, v)) = rest.split_once(':') {
                    total += v.trim().trim_end_matches("ns").trim().parse::<f64>().unwrap_or(0.0);
                }
            }
        }
    }
    total
}

impl Apps {
    pub fn reset(&mut self) {
        self.wh.clear();
        self.prev.clear();
    }

    /// `dt` seconds since the previous call, `system_w` the battery draw over that time.
    pub fn sample(&mut self, dt: f64, system_w: f64) {
        let Ok(rd) = fs::read_dir("/proc") else { return };
        let mut now: HashMap<u32, (f64, f64)> = HashMap::new();
        let mut weights: HashMap<String, f64> = HashMap::new();
        for e in rd.flatten() {
            let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<u32>().ok()) else { continue };
            let Some(ticks) = cpu_ticks(pid) else { continue };
            let gpu = gpu_ns(pid);
            if let Some((t0, g0)) = self.prev.get(&pid) {
                let w = ((ticks - t0).max(0.0) / CLK_TCK) + GPU_WEIGHT * ((gpu - g0).max(0.0) / 1e9);
                if w > 0.0 {
                    *weights.entry(proc_name(pid)).or_default() += w;
                }
            }
            now.insert(pid, (ticks, gpu));
        }
        self.prev = now;
        if dt <= 0.0 || dt > 120.0 || system_w <= 0.0 {
            return;
        }
        let total: f64 = weights.values().sum();
        // under half a core of work, the rest of the draw is the machine being on
        let busy_share = (total / (dt * 0.5)).min(1.0);
        let wh = system_w * dt / 3600.0;
        if total > 0.0 {
            for (name, w) in weights {
                *self.wh.entry(name).or_default() += wh * busy_share * w / total;
            }
        }
        *self.wh.entry("System idle".into()).or_default() += wh * (1.0 - busy_share);
    }

    pub fn top_json(&self, n: usize) -> String {
        let total: f64 = self.wh.values().sum();
        let mut v: Vec<(&String, &f64)> = self.wh.iter().collect();
        v.sort_by(|a, b| b.1.partial_cmp(a.1).unwrap_or(std::cmp::Ordering::Equal));
        let rows: Vec<_> = v
            .into_iter()
            .take(n)
            .map(|(k, w)| serde_json::json!({"name": k, "energy_wh": (w * 1000.0).round() / 1000.0, "pct_share": ((w / total.max(1e-9)) * 100.0).round()}))
            .collect();
        serde_json::Value::Array(rows).to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_cleaned_for_nix_wrappers() {
        assert_eq!(clean(".firefox-wrapped"), "firefox");
        assert_eq!(clean("kitty"), "kitty");
    }

    #[test]
    fn json_is_ranked_with_shares() {
        let mut a = Apps::default();
        a.wh.insert("small".into(), 1.0);
        a.wh.insert("big".into(), 3.0);
        let j: serde_json::Value = serde_json::from_str(&a.top_json(5)).unwrap();
        assert_eq!(j[0]["name"], "big");
        assert_eq!(j[0]["pct_share"], 75.0);
    }
}
