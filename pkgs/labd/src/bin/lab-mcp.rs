//! lab-mcp: MCP server (stdio, one JSON-RPC message per line) for the Kowal Lab desk.
//!
//! Reads go straight to the bus socket. Actions reuse the same CLIs the palette runs
//! (`lab`, `focus`, `room`, `loginctl`, `systemctl`), so the island, scenes and LED layer
//! see exactly what a keypress would have produced. Power actions need `confirm: true`.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::Command;
use std::time::{Duration, Instant};

use labd::bus::{make_event, sock_path};
use serde_json::{json, Value};

const MAX_EVENTS: usize = 100;
const MAX_WATCH_SECS: f64 = 30.0;

type Res = Result<String, String>;

fn bus_connect() -> Result<UnixStream, String> {
    UnixStream::connect(sock_path()).map_err(|e| format!("lab bus unreachable ({e}), is labd running?"))
}

fn bus_request(req: &Value) -> Result<Value, String> {
    let mut s = bus_connect()?;
    s.set_read_timeout(Some(Duration::from_secs(5))).ok();
    writeln!(s, "{req}").map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line).map_err(|e| e.to_string())?;
    let v: Value = serde_json::from_str(line.trim()).map_err(|e| format!("bad bus reply: {e}"))?;
    if v["ok"] == json!(true) {
        Ok(v)
    } else {
        Err(v["error"].as_str().unwrap_or("bus refused the request").to_string())
    }
}

fn cli(prog: &str, args: &[&str]) -> Res {
    let out = Command::new(prog)
        .args(args)
        .output()
        .map_err(|e| format!("{prog}: {e}"))?;
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    let err = String::from_utf8_lossy(&out.stderr);
    if !err.trim().is_empty() {
        text.push_str(&err);
    }
    if out.status.success() {
        Ok(text.trim().to_string())
    } else {
        Err(format!("{prog} {} failed: {}", args.join(" "), text.trim()))
    }
}

fn sh(cmd: &str) -> Res {
    cli("sh", &["-c", cmd])
}

fn str_arg<'a>(a: &'a Value, key: &str) -> Result<&'a str, String> {
    a[key].as_str().filter(|s| !s.is_empty()).ok_or(format!("{key} is required"))
}

// names end up in file names and shell-free argv, still keep them boring
fn safe_name(s: &str) -> Result<&str, String> {
    if s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')) {
        Ok(s)
    } else {
        Err("names may only contain letters, digits, '.', '_' and '-'".into())
    }
}

fn watch_events(seconds: f64) -> Res {
    let mut s = bus_connect()?;
    writeln!(s, r#"{{"op":"subscribe"}}"#).map_err(|e| e.to_string())?;
    let deadline = Instant::now() + Duration::from_secs_f64(seconds.clamp(0.5, MAX_WATCH_SECS));
    let mut rd = BufReader::new(s.try_clone().map_err(|e| e.to_string())?);
    let mut line = String::new();
    rd.read_line(&mut line).map_err(|e| e.to_string())?; // ack
    let mut events = Vec::new();
    while events.len() < MAX_EVENTS {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        s.set_read_timeout(Some(left)).ok();
        line.clear();
        match rd.read_line(&mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                if let Ok(v) = serde_json::from_str::<Value>(line.trim()) {
                    events.push(v);
                }
            }
        }
    }
    Ok(serde_json::to_string_pretty(&events).unwrap_or_default())
}

fn power(a: &Value) -> Res {
    let action = str_arg(a, "action")?;
    if a["confirm"] != json!(true) {
        return Err(format!(
            "{action} needs confirm: true. Ask the user first, it ends their session."
        ));
    }
    match action {
        "suspend" => sh("loginctl lock-session && systemctl suspend"),
        "reboot" => sh("systemctl reboot"),
        "poweroff" => sh("systemctl poweroff"),
        _ => Err("action must be suspend, reboot or poweroff".into()),
    }
    .map(|o| if o.is_empty() { format!("{action} requested") } else { o })
}

fn room(a: &Value) -> Res {
    let action = str_arg(a, "action")?;
    match action {
        "list" => cli("room", &["list"]),
        "save" => {
            let name = safe_name(str_arg(a, "name")?)?;
            if a["all"] == json!(true) {
                cli("room", &["save", name, "--all"])
            } else {
                cli("room", &["save", name])
            }
        }
        "open" => cli("room", &["open", safe_name(str_arg(a, "name")?)?]),
        _ => Err("action must be list, save or open".into()),
    }
}

fn focus(a: &Value) -> Res {
    match str_arg(a, "state")? {
        "on" => {
            let minutes = a["minutes"].as_u64().unwrap_or(25).to_string();
            cli("focus", &["on", &minutes])
        }
        "off" => cli("focus", &["off"]),
        "status" => cli("focus", &["status"]),
        _ => Err("state must be on, off or status".into()),
    }
}

fn publish(a: &Value) -> Res {
    let mut raw = json!({"name": a["name"], "source": a["source"].as_str().unwrap_or("mcp")});
    for k in ["payload", "priority", "ttl"] {
        if !a[k].is_null() {
            raw[k] = a[k].clone();
        }
    }
    let event = make_event(&raw)?;
    bus_request(&json!({"op": "publish", "event": event}))?;
    Ok(format!("published {}", event["name"].as_str().unwrap_or("")))
}

fn roster() -> Res {
    let st = bus_request(&json!({"op": "state"}))?;
    let devices = &st["state"]["roster.changed"]["payload"]["devices"];
    if devices.is_null() {
        return Err("no roster event on the bus yet (lab-roster not running?)".into());
    }
    Ok(serde_json::to_string_pretty(devices).unwrap_or_default())
}

fn call(name: &str, a: &Value) -> Res {
    match name {
        "lab_status" => cli("lab", &["status"]),
        "lab_events" => watch_events(a["seconds"].as_f64().unwrap_or(5.0)),
        "lab_roster" => roster(),
        "lab_doctor" => cli("lab", &["doctor"]),
        "lab_keys" => cli("lab", &["keys"]),
        "lab_scenes" => cli("lab", &["scene"]),
        "lab_themes" => cli("lab", &["theme"]),
        "lab_publish" => publish(a),
        "lab_scene" => cli("lab", &["scene", safe_name(str_arg(a, "name")?)?]),
        "lab_theme" => cli("lab", &["theme", safe_name(str_arg(a, "name")?)?]),
        "lab_focus" => focus(a),
        "lab_room" => room(a),
        "lab_lock" => cli("loginctl", &["lock-session"]),
        "lab_power" => power(a),
        _ => Err(format!("unknown tool: {name}")),
    }
}

fn schema(props: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": props, "required": required})
}

fn tools() -> Value {
    let none = || schema(json!({}), &[]);
    let t = |name: &str, desc: &str, input: Value, read_only: bool, destructive: bool| {
        json!({
            "name": name,
            "description": desc,
            "inputSchema": input,
            "annotations": {"readOnlyHint": read_only, "destructiveHint": destructive},
        })
    };
    json!([
        t("lab_status", "Last event per name on the Lab state bus, with age and whether it is stale.", none(), true, false),
        t("lab_events", "Listen on the bus for a few seconds and return the events that arrive.",
          schema(json!({"seconds": {"type": "number", "minimum": 0.5, "maximum": MAX_WATCH_SECS, "default": 5}}), &[]), true, false),
        t("lab_roster", "Devices on the tailnet roster (host, title, kind, os, online, self).", none(), true, false),
        t("lab_doctor", "Run the Lab health check: bus, tailnet, hub hooks, services, tokens, keymap, bar, sound.", none(), true, false),
        t("lab_keys", "Print the Lab keymap.", none(), true, false),
        t("lab_scenes", "List scenes with their step counts.", none(), true, false),
        t("lab_themes", "List theme packs and mark the active one.", none(), true, false),
        t("lab_publish", "Publish an event to the bus. The island decides how to present it.",
          schema(json!({
              "name": {"type": "string", "description": "dotted lowercase, e.g. focus.on"},
              "source": {"type": "string", "default": "mcp"},
              "payload": {"type": "object"},
              "priority": {"type": "string", "enum": ["low", "normal", "high"]},
              "ttl": {"type": "number", "description": "seconds until the event is stale"}
          }), &["name"]), false, false),
        t("lab_scene", "Run a scene by name (see lab_scenes). Steps are shell commands from the Nix config.",
          schema(json!({"name": {"type": "string"}}), &["name"]), false, false),
        t("lab_theme", "Switch the theme pack. Restarts labd to reload tokens.",
          schema(json!({"name": {"type": "string"}}), &["name"]), false, false),
        t("lab_focus", "Fleet-wide focus mode through the hub.",
          schema(json!({"state": {"type": "string", "enum": ["on", "off", "status"]}, "minutes": {"type": "integer", "default": 25}}), &["state"]), false, false),
        t("lab_room", "Project rooms: list, save the current workspace (or all with all=true) or open a saved one.",
          schema(json!({"action": {"type": "string", "enum": ["list", "save", "open"]}, "name": {"type": "string"}, "all": {"type": "boolean"}}), &["action"]), false, false),
        t("lab_lock", "Lock the session.", none(), false, false),
        t("lab_power", "Suspend (locks first), reboot or power off this machine. Requires confirm: true, ask the user before setting it.",
          schema(json!({"action": {"type": "string", "enum": ["suspend", "reboot", "poweroff"]}, "confirm": {"type": "boolean"}}), &["action", "confirm"]), false, true),
    ])
}

fn reply(id: &Value, result: Value) {
    println!("{}", json!({"jsonrpc": "2.0", "id": id, "result": result}));
}

fn reply_err(id: &Value, code: i32, message: &str) {
    println!("{}", json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}));
}

fn handle(msg: &Value) {
    let id = &msg["id"];
    if id.is_null() {
        return; // notifications get no reply
    }
    match msg["method"].as_str().unwrap_or_default() {
        "initialize" => reply(
            id,
            json!({
                "protocolVersion": msg["params"]["protocolVersion"].as_str().unwrap_or("2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "kowallab", "version": env!("CARGO_PKG_VERSION")},
            }),
        ),
        "tools/list" => reply(id, json!({"tools": tools()})),
        "tools/call" => {
            let name = msg["params"]["name"].as_str().unwrap_or_default();
            let args = &msg["params"]["arguments"];
            let (text, is_error) = match call(name, args) {
                Ok(t) => (if t.is_empty() { "ok".to_string() } else { t }, false),
                Err(e) => (e, true),
            };
            reply(id, json!({"content": [{"type": "text", "text": text}], "isError": is_error}));
        }
        "ping" => reply(id, json!({})),
        other => reply_err(id, -32601, &format!("method not found: {other}")),
    }
}

fn main() {
    for line in std::io::stdin().lock().lines().map_while(Result::ok) {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Value>(&line) {
            Ok(msg) => handle(&msg),
            Err(_) => reply_err(&Value::Null, -32700, "parse error"),
        }
        std::io::stdout().flush().ok();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn power_needs_confirm() {
        let err = power(&json!({"action": "reboot"})).unwrap_err();
        assert!(err.contains("confirm"));
    }

    #[test]
    fn names_stay_boring() {
        assert!(safe_name("school-2026.a").is_ok());
        assert!(safe_name("a b").is_err());
        assert!(safe_name("../x").is_err());
    }

    #[test]
    fn tool_names_are_unique_and_power_is_marked_destructive() {
        let list = tools();
        let names: Vec<&str> = list.as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        let mut sorted = names.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), names.len());
        let power = list.as_array().unwrap().iter().find(|t| t["name"] == "lab_power").unwrap();
        assert_eq!(power["annotations"]["destructiveHint"], json!(true));
    }

    #[test]
    fn publish_rejects_bad_names_before_touching_the_bus() {
        assert!(publish(&json!({"name": "Bad Name"})).is_err());
    }
}
