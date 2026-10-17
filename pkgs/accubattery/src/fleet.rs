//! One line of battery state for the rest of the tailnet. The roster script on other devices
//! reads it; only the tailscale address is bound, so nothing is exposed on the LAN.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const PORT: u16 = 47651;

fn tailscale_ip() -> Option<String> {
    let out = Command::new("tailscale").args(["ip", "-4"]).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).lines().next().map(str::to_string)).flatten()
}

fn handle(mut s: TcpStream, body: &str) {
    let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = s.set_write_timeout(Some(Duration::from_secs(2)));
    let mut buf = [0u8; 512];
    let _ = s.read(&mut buf);
    let _ = write!(
        s,
        "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
}

pub fn serve(summary: Arc<Mutex<String>>) {
    std::thread::spawn(move || loop {
        let Some(ip) = tailscale_ip() else {
            std::thread::sleep(Duration::from_secs(60));
            continue;
        };
        match TcpListener::bind((ip.as_str(), PORT)) {
            Ok(l) => {
                for conn in l.incoming().flatten() {
                    let body = summary.lock().map(|b| b.clone()).unwrap_or_default();
                    handle(conn, &body);
                }
            }
            Err(_) => std::thread::sleep(Duration::from_secs(60)),
        }
    });
}
