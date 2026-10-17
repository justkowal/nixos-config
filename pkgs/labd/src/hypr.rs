//! Hyprland IPC: commands over `.socket.sock`, events over `.socket2.sock`.
//! Used by the bar for workspaces. Every function degrades to "nothing" when Hyprland is not there.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

use serde_json::Value;

#[derive(Clone, Debug, PartialEq)]
pub struct Workspace {
    pub id: i64,
    pub name: String,
}

fn dir() -> Option<PathBuf> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")?;
    let sig = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE")?;
    Some(PathBuf::from(runtime).join("hypr").join(sig))
}

/// One command, one answer. `j/workspaces` style requests return JSON.
pub fn request(cmd: &str) -> Option<String> {
    let mut s = UnixStream::connect(dir()?.join(".socket.sock")).ok()?;
    s.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    s.write_all(cmd.as_bytes()).ok()?;
    let mut out = String::new();
    s.read_to_string(&mut out).ok()?;
    Some(out)
}

/// Regular workspaces in id order (special workspaces have negative ids and are not shown).
pub fn parse_workspaces(json: &str) -> Vec<Workspace> {
    let mut v: Vec<Workspace> = serde_json::from_str::<Value>(json)
        .ok()
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|w| {
            let id = w["id"].as_i64()?;
            (id > 0).then(|| Workspace {
                id,
                name: w["name"].as_str().unwrap_or("").to_owned(),
            })
        })
        .collect();
    v.sort_by_key(|w| w.id);
    v
}

pub fn workspaces() -> Vec<Workspace> {
    request("j/workspaces")
        .map(|j| parse_workspaces(&j))
        .unwrap_or_default()
}

pub fn active_workspace() -> Option<i64> {
    serde_json::from_str::<Value>(&request("j/activeworkspace")?).ok()?["id"].as_i64()
}

pub fn switch_to(id: i64) {
    let _ = request(&format!("dispatch workspace {id}"));
}

/// Events worth redrawing the workspace list for.
pub fn is_workspace_event(line: &str) -> bool {
    let name = line.split(">>").next().unwrap_or("");
    matches!(
        name,
        "workspace"
            | "workspacev2"
            | "createworkspace"
            | "createworkspacev2"
            | "destroyworkspace"
            | "destroyworkspacev2"
            | "focusedmon"
            | "focusedmonv2"
            | "moveworkspace"
            | "moveworkspacev2"
    )
}

/// Blocks forever, sending each workspace-relevant event line. Reconnects when Hyprland restarts.
pub fn follow_events(tx: async_channel::Sender<String>) {
    thread::spawn(move || loop {
        if let Some(path) = dir().map(|d| d.join(".socket2.sock")) {
            if let Ok(s) = UnixStream::connect(path) {
                for line in BufReader::new(s).lines().map_while(Result::ok) {
                    if is_workspace_event(&line) && tx.send_blocking(line).is_err() {
                        return;
                    }
                }
            }
        }
        thread::sleep(Duration::from_secs(2));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspaces_are_sorted_and_specials_hidden() {
        let json = r#"[{"id":3,"name":"3"},{"id":-98,"name":"special:minimized"},{"id":1,"name":"1"},{"id":2,"name":"web"}]"#;
        let ws = parse_workspaces(json);
        assert_eq!(ws.iter().map(|w| w.id).collect::<Vec<_>>(), vec![1, 2, 3]);
        assert_eq!(ws[1].name, "web");
        assert!(parse_workspaces("not json").is_empty());
        assert!(parse_workspaces("{}").is_empty());
    }

    #[test]
    fn only_workspace_events_redraw() {
        assert!(is_workspace_event("workspacev2>>2,2"));
        assert!(is_workspace_event("createworkspacev2>>4,4"));
        assert!(is_workspace_event("destroyworkspace>>4"));
        assert!(!is_workspace_event("activewindow>>kitty,foo"));
        assert!(!is_workspace_event("openwindow>>abc,1,kitty,foo"));
    }

    #[test]
    fn request_against_a_fake_socket() {
        use std::os::unix::net::UnixListener;
        let dir = std::env::temp_dir().join(format!("hypr-test-{}", std::process::id()));
        let inst = dir.join("hypr").join("sig");
        std::fs::create_dir_all(&inst).unwrap();
        let listener = UnixListener::bind(inst.join(".socket.sock")).unwrap();
        thread::spawn(move || {
            for mut s in listener.incoming().flatten() {
                let mut cmd = [0u8; 64];
                let n = s.read(&mut cmd).unwrap_or(0);
                let reply = match &cmd[..n] {
                    b"j/workspaces" => r#"[{"id":1,"name":"1"},{"id":2,"name":"2"}]"#,
                    b"j/activeworkspace" => r#"{"id":2,"name":"2"}"#,
                    _ => "ok",
                };
                let _ = s.write_all(reply.as_bytes());
            }
        });
        // env is process wide, so this is the only test that touches it
        std::env::set_var("XDG_RUNTIME_DIR", &dir);
        std::env::set_var("HYPRLAND_INSTANCE_SIGNATURE", "sig");
        assert_eq!(workspaces().len(), 2);
        assert_eq!(active_workspace(), Some(2));
        assert_eq!(request("dispatch workspace 2").as_deref(), Some("ok"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
