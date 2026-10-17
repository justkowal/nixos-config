use std::fs;
use std::path::{Path, PathBuf};

use crate::engine::{Sample, Status};

pub struct Battery {
    pub name: String,
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
        Self::find_all().into_iter().next()
    }

    /// Every battery, sorted by name, so BAT0 stays the primary one.
    pub fn find_all() -> Vec<Self> {
        let root = Path::new("/sys/class/power_supply");
        let Ok(rd) = fs::read_dir(root) else { return Vec::new() };
        let mut bats = Vec::new();
        let mut ac = None;
        for e in rd.flatten() {
            let p = e.path();
            match fs::read_to_string(p.join("type")).unwrap_or_default().trim() {
                "Battery" if p.join("capacity").exists() => bats.push(p),
                "Mains" | "USB" if ac.is_none() && p.join("online").exists() => ac = Some(p),
                _ => {}
            }
        }
        bats.sort();
        bats.into_iter()
            .map(|dir| Self { name: dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(), dir, ac: ac.clone() })
            .filter(|b| b.present())
            .collect()
    }

    fn present(&self) -> bool {
        num(&self.dir, "present").is_none_or(|v| v >= 1.0)
    }

    /// Charge stop and start thresholds in percent when the firmware exposes them.
    pub fn thresholds(&self) -> (Option<i64>, Option<i64>) {
        let rd = |names: [&str; 2]| names.iter().find_map(|n| num(&self.dir, n)).map(|v| v as i64);
        (
            rd(["charge_control_end_threshold", "charge_stop_threshold"]),
            rd(["charge_control_start_threshold", "charge_start_threshold"]),
        )
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

impl Battery {
    /// Direct write, only works where sysfs is writable for the user. Both attribute spellings are tried.
    pub fn write_thresholds(&self, start: i64, stop: i64) -> std::io::Result<()> {
        let mut wrote = false;
        let mut last = Ok(());
        for (names, v) in [(["charge_control_start_threshold", "charge_start_threshold"], start), (["charge_control_end_threshold", "charge_stop_threshold"], stop)] {
            for n in names {
                let p = self.dir.join(n);
                if p.exists() {
                    match fs::write(&p, v.to_string()) {
                        Ok(()) => wrote = true,
                        Err(e) => last = Err(e),
                    }
                }
            }
        }
        if wrote { Ok(()) } else { last.and(Err(std::io::Error::other("no threshold files"))) }
    }
}

pub fn abm_files() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Ok(rd) = fs::read_dir("/sys/class/drm") {
        for e in rd.flatten() {
            let p = e.path().join("amdgpu/panel_power_savings");
            if p.exists() {
                v.push(p);
            }
        }
    }
    v
}

/// modules/power-saving.nix makes these world writable, so no privilege is needed
pub fn set_abm(level: u8) -> std::io::Result<()> {
    let files = abm_files();
    if files.is_empty() {
        return Err(std::io::Error::other("no panel_power_savings"));
    }
    for f in files {
        fs::write(f, level.to_string())?;
    }
    Ok(())
}

/// Adapter identity for the charge profile: the negotiated PD revision when known.
pub fn adapter_key(sample: &Sample) -> String {
    pd_label(sample).map(|l| l.split(" (").next().unwrap_or("AC").to_string()).unwrap_or_else(|| "AC".into())
}

pub fn hostname() -> String {
    fs::read_to_string("/proc/sys/kernel/hostname").map(|s| s.trim().to_string()).unwrap_or_default()
}
