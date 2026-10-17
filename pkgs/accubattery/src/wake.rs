//! Wakeup sources the kernel exposes without root, diffed across a suspend to name the culprit.

use std::collections::HashMap;
use std::fs;

pub type Snap = HashMap<String, (u64, u64)>;

pub fn snapshot() -> Snap {
    let mut m = Snap::new();
    let Ok(rd) = fs::read_dir("/sys/class/wakeup") else { return m };
    for e in rd.flatten() {
        let p = e.path();
        let rd = |f: &str| fs::read_to_string(p.join(f)).ok().map(|s| s.trim().to_string());
        let (Some(name), Some(count)) = (rd("name"), rd("wakeup_count")) else { continue };
        let ms = rd("total_time_ms").and_then(|s| s.parse().ok()).unwrap_or(0);
        let entry = m.entry(name).or_insert((0, 0));
        entry.0 += count.parse().unwrap_or(0);
        entry.1 += ms;
    }
    m
}

/// Top sources that woke the machine between the two snapshots, as a JSON array string.
pub fn culprits(before: &Snap, after: &Snap) -> Option<String> {
    let mut v: Vec<(String, u64, u64)> = after
        .iter()
        .filter_map(|(k, (c, ms))| {
            let (c0, ms0) = before.get(k).copied().unwrap_or((0, 0));
            (*c > c0).then(|| (k.clone(), c - c0, ms.saturating_sub(ms0)))
        })
        .collect();
    if v.is_empty() {
        return None;
    }
    v.sort_by(|a, b| b.2.cmp(&a.2).then(b.1.cmp(&a.1)));
    let top: Vec<_> = v.into_iter().take(3).map(|(n, c, ms)| serde_json::json!({"name": n, "count": c, "ms": ms})).collect();
    Some(serde_json::Value::Array(top).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diff_ranks_by_active_time() {
        let mut a = Snap::new();
        a.insert("lid".into(), (1, 10));
        a.insert("nvme".into(), (5, 100));
        let mut b = a.clone();
        b.insert("lid".into(), (2, 12));
        b.insert("nvme".into(), (9, 4000));
        b.insert("same".into(), (0, 0));
        let j = culprits(&a, &b).unwrap();
        assert!(j.find("nvme").unwrap() < j.find("lid").unwrap());
        assert!(!j.contains("same"));
        assert!(culprits(&b, &b).is_none());
    }
}
