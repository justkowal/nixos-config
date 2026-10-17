//! Reactions to bus events that are not drawing: scene triggers and sounds.
//! Scenes themselves run in `lab scene` (home/scripts/lab.py); labd only starts them.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::tokens::Tokens;

/// A scene must not retrigger itself through its own side effects.
const DEBOUNCE: Duration = Duration::from_secs(5);

pub struct Scene {
    name: String,
    on: Vec<String>,
}

pub struct Engine {
    scenes: Vec<Scene>,
    sounds: HashMap<String, String>,
    sound_enabled: bool,
    last_run: RefCell<HashMap<String, Instant>>,
}

fn load_scenes() -> Vec<Scene> {
    let file = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .map(|d| d.join("lab/scenes.json"));
    let raw = file
        .and_then(|f| std::fs::read_to_string(f).ok())
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .unwrap_or(Value::Null);
    raw.as_object()
        .map(|o| {
            o.iter()
                .map(|(name, sc)| Scene {
                    name: name.clone(),
                    on: sc["on"]
                        .as_array()
                        .map(|a| {
                            a.iter()
                                .filter_map(|e| e.as_str().map(str::to_owned))
                                .collect()
                        })
                        .unwrap_or_default(),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Which sound key (a name in the tokens `sound` map) an event plays, if any.
/// Sounds are for scene changes and handoff only, never routine state.
pub fn sound_key(ev: &Value) -> Option<&'static str> {
    match ev["name"].as_str()? {
        "scene.done" if ev["payload"]["failed"].as_u64().unwrap_or(0) > 0 => None,
        "scene.done" => Some(match ev["payload"]["name"].as_str() {
            Some("arrive") => "arrive",
            Some("leave") => "leave",
            _ => "scene",
        }),
        "handoff.arrived" => Some("handoff"),
        _ => None,
    }
}

impl Engine {
    pub fn new(tokens: &Tokens) -> Self {
        Engine {
            scenes: load_scenes(),
            sounds: tokens.sounds.clone(),
            sound_enabled: tokens.sound_enabled,
            last_run: RefCell::new(HashMap::new()),
        }
    }

    fn triggered(&self, ev: &Value) -> Vec<&str> {
        let name = ev["name"].as_str().unwrap_or_default();
        // events from scenes never start scenes
        if ev["source"] == "scene" {
            return Vec::new();
        }
        self.scenes
            .iter()
            .filter(|s| s.on.iter().any(|e| e == name))
            .map(|s| s.name.as_str())
            .collect()
    }

    pub fn handle(&self, ev: &Value) {
        for scene in self.triggered(ev) {
            let mut last = self.last_run.borrow_mut();
            if last.get(scene).is_some_and(|t| t.elapsed() < DEBOUNCE) {
                continue;
            }
            last.insert(scene.to_owned(), Instant::now());
            let scene = scene.to_owned();
            // the scene command waits on its steps, so keep it off the main loop
            std::thread::spawn(move || {
                let _ = Command::new("lab").args(["scene", &scene]).status();
            });
        }
        if self.sound_enabled {
            if let Some(theme_name) = sound_key(ev).and_then(|k| self.sounds.get(k)) {
                let theme_name = theme_name.clone();
                std::thread::spawn(move || {
                    let _ = Command::new("canberra-gtk-play")
                        .args(["-i", &theme_name])
                        .status();
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn engine() -> Engine {
        Engine {
            scenes: vec![
                Scene {
                    name: "arrive".into(),
                    on: vec!["handoff.arrived".into()],
                },
                Scene {
                    name: "focus".into(),
                    on: vec![],
                },
            ],
            sounds: HashMap::new(),
            sound_enabled: false,
            last_run: RefCell::new(HashMap::new()),
        }
    }

    #[test]
    fn scenes_start_on_their_events_only() {
        let e = engine();
        let ev = json!({"name": "handoff.arrived", "source": "home-lan"});
        assert_eq!(e.triggered(&ev), vec!["arrive"]);
        assert!(e
            .triggered(&json!({"name": "focus.on", "source": "focus"}))
            .is_empty());
    }

    #[test]
    fn scene_events_never_start_scenes() {
        let ev = json!({"name": "handoff.arrived", "source": "scene"});
        assert!(engine().triggered(&ev).is_empty());
    }

    #[test]
    fn sounds_only_for_scenes_and_handoff() {
        let done = |name: &str, failed: u64| json!({"name": "scene.done", "payload": {"name": name, "failed": failed}});
        assert_eq!(sound_key(&done("arrive", 0)), Some("arrive"));
        assert_eq!(sound_key(&done("leave", 0)), Some("leave"));
        assert_eq!(sound_key(&done("focus", 0)), Some("scene"));
        assert_eq!(sound_key(&done("focus", 1)), None);
        assert_eq!(
            sound_key(&json!({"name": "handoff.arrived"})),
            Some("handoff")
        );
        assert_eq!(sound_key(&json!({"name": "volume.changed"})), None);
        assert_eq!(sound_key(&json!({"name": "focus.on"})), None);
    }
}
