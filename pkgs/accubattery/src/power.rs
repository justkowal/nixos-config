//! Keeps the machine awake while charging (so the session is logged) and, once the
//! charge is done and nobody is around, sleeps it or powers it off at night.

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

use serde::Serialize;

const IDLE_GRACE_S: f64 = 180.0;

#[derive(Serialize, Clone, Default)]
pub struct PowerInfo {
    pub mode: &'static str,
    pub countdown_remaining: u64,
    pub action: &'static str,
}

pub struct PowerPolicy {
    inhibitor: Option<Child>,
    done_since: Option<f64>,
    was_charging: bool,
    runtime: PathBuf,
}

fn quiet(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("timeout")
        .arg("2")
        .arg(cmd)
        .args(args)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

fn hour_now() -> u32 {
    quiet("date", &["+%H"]).and_then(|s| s.trim().parse().ok()).unwrap_or(12)
}

impl PowerPolicy {
    pub fn new() -> Self {
        let runtime = std::env::var("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|_| "/tmp".into());
        Self { inhibitor: None, done_since: None, was_charging: false, runtime }
    }

    fn caffeine(&self) -> bool {
        self.runtime.join("caffeine.active").exists()
    }

    fn external_inhibitor(&self) -> bool {
        let pid_file = self.runtime.join("accubattery_charging.pid");
        match std::fs::read_to_string(&pid_file).ok().and_then(|s| s.trim().parse::<u32>().ok()) {
            Some(pid) if std::path::Path::new(&format!("/proc/{pid}")).exists() => true,
            Some(_) => {
                let _ = std::fs::remove_file(pid_file);
                false
            }
            None => false,
        }
    }

    fn inactive(&self) -> bool {
        if let Ok(rd) = std::fs::read_dir("/proc/acpi/button/lid") {
            for e in rd.flatten() {
                if std::fs::read_to_string(e.path().join("state")).is_ok_and(|s| s.contains("closed")) {
                    return true;
                }
            }
        }
        if quiet("pidof", &["hyprlock"]).is_some() {
            return true;
        }
        if let Some(j) = quiet("hyprctl", &["monitors", "-j"]).and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok()) {
            if let Some(m) = j.as_array().filter(|m| !m.is_empty()) {
                if m.iter().all(|m| m["dpmsStatus"] == false) {
                    return true;
                }
            }
        }
        // the user's own session, not every session on the box
        if let Some(out) = quiet("loginctl", &["show-user", "--property=Sessions", "--value", &std::env::var("USER").unwrap_or_default()]) {
            for id in out.split_whitespace() {
                if let Some(p) = quiet("loginctl", &["show-session", id, "-p", "LockedHint", "-p", "IdleHint"]) {
                    if p.contains("LockedHint=yes") || p.contains("IdleHint=yes") {
                        return true;
                    }
                }
            }
        }
        false
    }

    fn release(&mut self) {
        if let Some(mut c) = self.inhibitor.take() {
            let _ = c.kill();
            let _ = c.wait();
            let _ = std::fs::remove_file(self.runtime.join("accubattery_charging.pid"));
        }
    }

    pub fn update(&mut self, charging: bool, idle_full: bool, keep_awake: bool, now: f64) -> PowerInfo {
        let mut info = PowerInfo { mode: "standard", countdown_remaining: 0, action: "suspend" };
        if charging {
            self.was_charging = true;
            self.done_since = None;
            if !keep_awake {
                self.release();
                return info;
            }
            info.mode = "charging_awake";
            if self.inhibitor.is_none() && !self.external_inhibitor() && !self.caffeine() {
                self.inhibitor = Command::new("systemd-inhibit")
                    .args([
                        "--what=sleep:handle-lid-switch:idle",
                        "--who=AccuBattery Charging",
                        "--why=Logging charge session telemetry",
                        "--mode=block",
                        "sleep",
                        "infinity",
                    ])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .ok();
                if let Some(c) = &self.inhibitor {
                    let _ = std::fs::write(self.runtime.join("accubattery_charging.pid"), c.id().to_string());
                }
            }
            return info;
        }

        self.release();
        if self.was_charging && idle_full {
            self.done_since.get_or_insert(now);
        } else if !idle_full {
            self.done_since = None;
        }
        let Some(since) = self.done_since else { return info };

        if self.caffeine() {
            info.mode = "caffeine_manual";
            return info;
        }
        if !self.inactive() {
            self.done_since = None;
            info.mode = "charged_active";
            return info;
        }
        let elapsed = now - since;
        let night = hour_now() < 5;
        info.mode = "countdown";
        info.action = if night { "poweroff" } else { "suspend" };
        info.countdown_remaining = (IDLE_GRACE_S - elapsed).max(0.0) as u64;
        if elapsed >= IDLE_GRACE_S {
            self.done_since = None;
            self.was_charging = false;
            let _ = Command::new("systemctl").arg(info.action).status();
        }
        info
    }
}

impl Drop for PowerPolicy {
    fn drop(&mut self) {
        self.release();
    }
}
