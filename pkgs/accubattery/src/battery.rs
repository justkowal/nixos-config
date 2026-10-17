use std::fs;
use std::path::{Path, PathBuf};

use crate::engine::{Sample, Status};

pub struct Battery {
    dir: PathBuf,
    ac: Option<PathBuf>,
}

fn num(p: &Path, name: &str) -> Option<f64> {
    fs::read_to_string(p.join(name)).ok()?.trim().parse().ok()
}

pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

pub fn boot_id() -> String {
    fs::read_to_string("/proc/sys/kernel/random/boot_id").unwrap_or_default().trim().to_string()
}

impl Battery {
    pub fn find() -> Option<Self> {
        let root = Path::new("/sys/class/power_supply");
        let mut bat = None;
        let mut ac = None;
        for e in fs::read_dir(root).ok()?.flatten() {
            let p = e.path();
            match fs::read_to_string(p.join("type")).unwrap_or_default().trim() {
                "Battery" if bat.is_none() && p.join("capacity").exists() => bat = Some(p),
                "Mains" | "USB" if ac.is_none() && p.join("online").exists() => ac = Some(p),
                _ => {}
            }
        }
        Some(Self { dir: bat?, ac })
    }

    pub fn ac_online(&self) -> bool {
        self.ac.as_ref().and_then(|p| num(p, "online")).is_some_and(|v| v >= 1.0)
    }

    pub fn cycle_count(&self) -> i64 {
        num(&self.dir, "cycle_count").map(|v| v as i64).unwrap_or(0)
    }

    pub fn design_wh(&self) -> f64 {
        num(&self.dir, "energy_full_design").unwrap_or(0.0) / 1e6
    }

    pub fn sample(&self) -> Option<Sample> {
        let d = &self.dir;
        let status = fs::read_to_string(d.join("status")).ok()?;
        let ac = self.ac_online();
        let cap = num(d, "capacity")?;
        let full_wh = num(d, "energy_full").unwrap_or(0.0) / 1e6;
        // energy_now gives sub-percent resolution; capacity is an integer
        let (wh, pct) = match num(d, "energy_now") {
            Some(e) if full_wh > 0.0 => (e / 1e6, (e / 1e6 / full_wh * 100.0).min(100.0)),
            _ => (cap / 100.0 * full_wh, cap),
        };
        let watts = num(d, "power_now").unwrap_or(0.0) / 1e6;
        let volts = num(d, "voltage_now").unwrap_or(0.0) / 1e6;
        let status = match status.trim() {
            "Charging" => Status::Charging,
            "Discharging" => Status::Discharging,
            // a few firmwares report Unknown while on battery
            "Unknown" if !ac => Status::Discharging,
            _ => Status::Idle,
        };
        Some(Sample {
            wall: now(),
            boot_id: boot_id(),
            status,
            ac,
            pct,
            wh,
            full_wh,
            watts,
            volts,
            ma: if volts > 0.0 { watts / volts * 1000.0 } else { 0.0 },
            temp: self.temp(),
        })
    }

    fn temp(&self) -> f64 {
        if let Some(v) = num(&self.dir, "temp") {
            return if v < 1000.0 { v / 10.0 } else { v / 1000.0 };
        }
        0.0
    }
}

/// Negotiated USB-PD revision of the attached partner, if the kernel exposes it
pub fn pd_label(sample: &Sample) -> Option<String> {
    if !sample.ac {
        return None;
    }
    let mut rev = None;
    for e in fs::read_dir("/sys/class/typec").ok()?.flatten() {
        let name = e.file_name();
        if name.to_string_lossy().ends_with("-partner") {
            if let Ok(r) = fs::read_to_string(e.path().join("usb_power_delivery/revision")) {
                rev = Some(r.trim().to_string());
            }
        }
    }
    let rev = rev.map(|r| format!("USB-PD {r}")).unwrap_or_else(|| "AC".into());
    Some(if sample.status == Status::Charging { format!("{rev} ({:.0} W)", sample.watts) } else { rev })
}
