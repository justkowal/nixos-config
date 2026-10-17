//! Kowal Lab state bus: newline-delimited JSON over a unix socket.
//!
//! Protocol (shared with `home/scripts/guis/lab_bus.py`, the client side):
//!   {"op":"publish","event":{name,source,payload,priority,ttl}} -> {"ok":true}
//!   {"op":"state"} -> {"ok":true,"state":{name:event}}
//!   {"op":"subscribe"} -> {"ok":true}, then one event per line

use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

pub fn sock_path() -> PathBuf {
    let dir =
        std::env::var_os("XDG_RUNTIME_DIR").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    dir.join("lab.sock")
}

fn valid_name(name: &str) -> bool {
    let parts: Vec<&str> = name.split('.').collect();
    parts.len() >= 2
        && parts.iter().all(|p| {
            let mut c = p.chars();
            c.next().is_some_and(|f| f.is_ascii_lowercase())
                && c.all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_')
        })
}

/// Validates the event contract and stamps it. Mirrors `make_event` in lab_bus.py.
pub fn make_event(raw: &Value) -> Result<Value, String> {
    let name = raw["name"].as_str().unwrap_or_default();
    if !valid_name(name) {
        return Err(format!(
            "event name must be dotted lowercase (focus.on), got {name:?}"
        ));
    }
    let source = raw["source"].as_str().unwrap_or_default();
    if source.is_empty() {
        return Err("event source is required".into());
    }
    let payload = match &raw["payload"] {
        Value::Null => json!({}),
        p @ Value::Object(_) => p.clone(),
        _ => return Err("event payload must be a JSON object".into()),
    };
    let priority = match raw["priority"].as_str() {
        None => "normal",
        Some(p @ ("low" | "normal" | "high")) => p,
        Some(_) => return Err("priority must be one of low, normal, high".into()),
    };
    let ttl = match &raw["ttl"] {
        Value::Null => 30.0,
        v => v
            .as_f64()
            .filter(|t| *t > 0.0)
            .ok_or("ttl must be a positive number of seconds")?,
    };
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    Ok(
        json!({"name": name, "source": source, "payload": payload, "priority": priority, "ttl": ttl, "ts": ts}),
    )
}

pub struct Bus {
    state: Mutex<HashMap<String, Value>>,
    subs: Mutex<Vec<UnixStream>>,
    tx: async_channel::Sender<Value>,
}

impl Bus {
    pub fn new() -> (Arc<Bus>, async_channel::Receiver<Value>) {
        let (tx, rx) = async_channel::unbounded();
        let bus = Bus {
            state: Mutex::new(HashMap::new()),
            subs: Mutex::new(Vec::new()),
            tx,
        };
        (Arc::new(bus), rx)
    }

    pub fn publish(&self, ev: Value) {
        let name = ev["name"].as_str().unwrap_or_default().to_owned();
        self.state.lock().unwrap().insert(name, ev.clone());
        let line = format!("{ev}\n");
        self.subs
            .lock()
            .unwrap()
            .retain_mut(|s| s.write_all(line.as_bytes()).is_ok());
        // unbounded, so this never blocks; the receiver only goes away at shutdown
        let _ = self.tx.send_blocking(ev);
    }

    pub fn snapshot(&self) -> Value {
        json!(*self.state.lock().unwrap())
    }

    pub fn serve(self: &Arc<Self>, path: &Path) -> io::Result<()> {
        if path.exists() {
            if UnixStream::connect(path).is_ok() {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    format!("another bus is serving {}", path.display()),
                ));
            }
            std::fs::remove_file(path)?;
        }
        let listener = UnixListener::bind(path)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        let bus = Arc::clone(self);
        thread::Builder::new()
            .name("lab-bus".into())
            .spawn(move || {
                for stream in listener.incoming().flatten() {
                    let bus = Arc::clone(&bus);
                    thread::spawn(move || bus.handle(stream));
                }
            })?;
        Ok(())
    }

    fn handle(self: &Arc<Self>, stream: UnixStream) {
        let Ok(mut out) = stream.try_clone() else {
            return;
        };
        for line in BufReader::new(stream).lines().map_while(Result::ok) {
            let (reply, subscribe) = match serde_json::from_str::<Value>(&line) {
                Ok(msg) => self.dispatch(&msg),
                Err(e) => (json!({"ok": false, "error": e.to_string()}), false),
            };
            if writeln!(out, "{reply}").is_err() {
                return;
            }
            if subscribe {
                // a stuck subscriber must not stall publishers
                let _ = out.set_write_timeout(Some(Duration::from_millis(500)));
                if let Ok(sub) = out.try_clone() {
                    self.subs.lock().unwrap().push(sub);
                }
            }
        }
    }

    fn dispatch(&self, msg: &Value) -> (Value, bool) {
        match msg["op"].as_str() {
            Some("publish") => match make_event(&msg["event"]) {
                Ok(ev) => {
                    self.publish(ev);
                    (json!({"ok": true}), false)
                }
                Err(e) => (json!({"ok": false, "error": e}), false),
            },
            Some("state") => (json!({"ok": true, "state": self.snapshot()}), false),
            Some("subscribe") => (json!({"ok": true}), true),
            other => (
                json!({"ok": false, "error": format!("unknown op {other:?}")}),
                false,
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_sock(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!("labd-test-{tag}-{}.sock", std::process::id()))
    }

    fn rpc(path: &Path, msg: &Value) -> Value {
        let mut s = UnixStream::connect(path).unwrap();
        writeln!(s, "{msg}").unwrap();
        let mut line = String::new();
        BufReader::new(s).read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }

    #[test]
    fn rejects_bad_events() {
        for bad in [
            json!({"name": "Bad_Name", "source": "x"}),
            json!({"name": "focus", "source": "x"}),
            json!({"name": "focus.on"}),
            json!({"name": "focus.on", "source": "x", "payload": 3}),
            json!({"name": "focus.on", "source": "x", "priority": "urgent"}),
            json!({"name": "focus.on", "source": "x", "ttl": 0}),
        ] {
            assert!(make_event(&bad).is_err(), "{bad}");
        }
        assert!(make_event(&json!({"name": "room.restored", "source": "room"})).is_ok());
    }

    #[test]
    fn publish_state_and_subscribe() {
        let path = tmp_sock("pubsub");
        let (bus, rx) = Bus::new();
        bus.serve(&path).unwrap();

        let sub = UnixStream::connect(&path).unwrap();
        let mut sub_w = sub.try_clone().unwrap();
        writeln!(sub_w, r#"{{"op":"subscribe"}}"#).unwrap();
        let mut sub_r = BufReader::new(sub);
        let mut ack = String::new();
        sub_r.read_line(&mut ack).unwrap();
        assert!(ack.contains("\"ok\":true"));

        let ev = json!({"name": "focus.on", "source": "focus", "payload": {"minutes": 25}});
        assert_eq!(
            rpc(&path, &json!({"op": "publish", "event": ev}))["ok"],
            true
        );
        assert_eq!(
            rpc(&path, &json!({"op": "publish", "event": {"name": "x"}}))["ok"],
            false
        );

        let mut pushed = String::new();
        sub_r.read_line(&mut pushed).unwrap();
        let pushed: Value = serde_json::from_str(&pushed).unwrap();
        assert_eq!(pushed["name"], "focus.on");
        assert_eq!(pushed["payload"]["minutes"], 25);

        assert_eq!(rx.recv_blocking().unwrap()["name"], "focus.on");
        assert_eq!(
            rpc(&path, &json!({"op": "state"}))["state"]["focus.on"]["source"],
            "focus"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn stale_socket_is_replaced_and_live_one_is_refused() {
        let path = tmp_sock("stale");
        drop(UnixListener::bind(&path).unwrap());
        let (a, _ra) = Bus::new();
        a.serve(&path).unwrap();
        let (b, _rb) = Bus::new();
        assert_eq!(b.serve(&path).unwrap_err().kind(), io::ErrorKind::AddrInUse);
        let _ = std::fs::remove_file(path);
    }
}
