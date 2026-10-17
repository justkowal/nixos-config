//! Daemon to island: events go through lab-publish so the island is the only thing that draws state.
//! Falls back to swayosd-client when the bus client is not installed.

use std::process::{Command, Stdio};

fn reap(mut c: std::process::Child) {
    std::thread::spawn(move || {
        let _ = c.wait();
    });
}

pub fn publish(name: &str, payload: serde_json::Value, high: bool, fallback_text: &str) {
    let mut cmd = Command::new("lab-publish");
    cmd.args([name, "--source", "accubattery", "--payload", &payload.to_string()]);
    if high {
        cmd.args(["--priority", "high"]);
    }
    cmd.stdout(Stdio::null()).stderr(Stdio::null());
    match cmd.spawn() {
        Ok(c) => reap(c),
        Err(_) => {
            if let Ok(c) = Command::new("swayosd-client")
                .args(["--custom-message", fallback_text, "--custom-icon", "battery-good"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
            {
                reap(c);
            }
        }
    }
}
