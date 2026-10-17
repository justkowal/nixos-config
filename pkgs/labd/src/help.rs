//! The help app: every keybind (read live from Hyprland), what Lab can do, and a health check.
//! A normal floating window, opened with the `help.toggle` bus event (SUPER + /).

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gdk, glib};
use gtk4 as gtk;
use libadwaita as adw;
use serde_json::Value;

const GROUP_ORDER: &[&str] = &[
    "Shell",
    "Focus",
    "Rooms",
    "Devices",
    "Help",
    "Apps",
    "Windows",
    "Workspaces",
    "Screenshots",
    "Media and hardware",
    "System",
    "Resize mode",
    "Other",
];

#[derive(Clone, Debug, PartialEq)]
pub struct Bind {
    pub combo: Vec<String>,
    pub label: String,
    pub group: String,
}

fn config_file(name: &str) -> Option<PathBuf> {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .map(|d| d.join("lab").join(name))
}

fn read_json(name: &str) -> Value {
    config_file(name)
        .and_then(|f| std::fs::read_to_string(f).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null)
}

/// Modifier names in the order people read them. Caps lock and num lock bits are ignored.
pub fn mods_from_mask(mask: u64) -> Vec<&'static str> {
    [(64, "SUPER"), (4, "CTRL"), (8, "ALT"), (1, "SHIFT")]
        .into_iter()
        .filter(|(bit, _)| mask & bit != 0)
        .map(|(_, name)| name)
        .collect()
}

fn key_name(key: &str, keycode: u64) -> String {
    match key {
        "mouse:272" => "Left mouse".into(),
        "mouse:273" => "Right mouse".into(),
        "mouse:274" => "Middle mouse".into(),
        "mouse_down" => "Scroll down".into(),
        "mouse_up" => "Scroll up".into(),
        "" if keycode > 0 => format!("key {keycode}"),
        k if k.starts_with("switch:") => "Lid".into(),
        k => k.replace('_', " "),
    }
}

/// `$mod ALT` + `R` in keymap.json becomes the same id Hyprland's mask and key give: `SUPER+ALT+R`.
fn canon(mods: &[String], key: &str) -> String {
    let order = ["SUPER", "CTRL", "ALT", "SHIFT"];
    let upper: Vec<String> = mods
        .iter()
        .map(|m| {
            if m.eq_ignore_ascii_case("$mod") || m.eq_ignore_ascii_case("mod") {
                "SUPER".to_owned()
            } else {
                m.to_uppercase()
            }
        })
        .collect();
    let mut parts: Vec<&str> = order
        .iter()
        .copied()
        .filter(|o| upper.iter().any(|m| m == o))
        .collect();
    let key = key.to_uppercase();
    parts.push(&key);
    parts.join("+")
}

fn pretty(cmd: &str) -> String {
    let base = cmd.rsplit('/').next().unwrap_or(cmd);
    let base = base.trim_end_matches(".sh").replace(['-', '_'], " ");
    let mut c = base.chars();
    c.next().map_or(String::new(), |f| {
        f.to_uppercase().collect::<String>() + c.as_str()
    })
}

/// A readable label and group for binds that are not in the Lab keymap.
pub fn describe(dispatcher: &str, arg: &str) -> (String, String) {
    let g = |s: &str| s.to_owned();
    match dispatcher {
        "exec" => {
            let toks: Vec<&str> = arg.split_whitespace().collect();
            let first = toks.first().copied().unwrap_or("");
            let first_base = first.rsplit('/').next().unwrap_or(first);
            let rest = toks.get(1).copied().unwrap_or("");
            let second = toks.get(2).copied().unwrap_or("");
            if arg.contains("/bin/grim") || first_base == "grim" {
                let what = if arg.contains("slurp") {
                    "Screenshot a region"
                } else if arg.contains("activewindow") {
                    "Screenshot the window"
                } else if arg.contains("-o ") {
                    "Screenshot this screen"
                } else {
                    "Screenshot every screen"
                };
                return (g(what), g("Screenshots"));
            }
            if arg.contains("nmcli radio wifi") {
                return (g("Toggle Wi-Fi"), g("Media and hardware"));
            }
            if arg.contains("rfkill list bluetooth") {
                return (g("Toggle Bluetooth"), g("Media and hardware"));
            }
            let known = match (first_base, rest) {
                ("kitty", _) => Some(("Terminal", "Apps")),
                ("thunar", _) => Some(("Files", "Apps")),
                ("firefox", _) => Some(("Browser", "Apps")),
                ("control-center-gui", _) => Some(("Control center", "Apps")),
                ("lan-mouse-gui", _) => Some(("Mouse sharing", "Apps")),
                ("fleet-manager-gui", _) => Some(("Fleet manager", "Apps")),
                ("tablet-display-gui", _) => Some(("Tablet display studio", "Apps")),
                ("accubattery-gui", _) => Some(("Battery health", "Apps")),
                ("cliphist-picker", _) => Some(("Clipboard history", "Apps")),
                ("power-menu", _) => Some(("Power menu", "System")),
                ("change-wallpaper", _) => Some(("Cycle wallpaper and theme", "System")),
                ("caffeine", _) => Some(("Keep awake", "System")),
                ("monitor-ctl", "mode") => Some(("Display mode", "Media and hardware")),
                ("monitor-ctl", _) => Some(("Lid and display", "Media and hardware")),
                ("swaync-client", _) => Some(("Notification center", "System")),
                ("loginctl", "lock-session") => Some(("Lock screen", "System")),
                ("rofi", _) => Some(("App launcher", "Apps")),
                ("playerctl", "play-pause") => Some(("Play or pause", "Media and hardware")),
                ("playerctl", "next") => Some(("Next track", "Media and hardware")),
                ("playerctl", "previous") => Some(("Previous track", "Media and hardware")),
                ("volume-osd", "up") => Some(("Volume up", "Media and hardware")),
                ("volume-osd", "down") => Some(("Volume down", "Media and hardware")),
                ("volume-osd", "mute") => Some(("Mute", "Media and hardware")),
                ("volume-osd", "mic-mute") => Some(("Mute microphone", "Media and hardware")),
                ("brightness-osd", "up") => Some(("Brightness up", "Media and hardware")),
                ("brightness-osd", "down") => Some(("Brightness down", "Media and hardware")),
                ("tablet-display", _) => Some(("Tablet display on or off", "Apps")),
                ("resize-split", _) => None,
                _ => None,
            };
            if let Some((label, group)) = known {
                return (g(label), g(group));
            }
            if first_base == "resize-split" {
                let unit = if rest == "height" { "height" } else { "width" };
                return (format!("Resize to {second}% {unit}"), g("Resize mode"));
            }
            if first_base == "bash" {
                let script = if rest == "-c" { "" } else { rest };
                return match script.rsplit('/').next().unwrap_or("") {
                    "spotlight.sh" => (g("Spotlight search"), g("Apps")),
                    "rofi_ai.sh" => (g("AI assistant"), g("Apps")),
                    "notification_digest.sh" => (g("AI notification digest"), g("Apps")),
                    "ai_ocr_screenshot.sh" => (g("Screenshot with AI analysis"), g("Screenshots")),
                    "" => (g("Run a command"), g("Other")),
                    s => (pretty(s), g("Apps")),
                };
            }
            if first_base == "gdbus" && arg.contains("Widgets") {
                return (g("Toggle dashboard"), g("Shell"));
            }
            (pretty(first_base), g("Apps"))
        }
        "killactive" => (g("Close window"), g("Windows")),
        "togglefloating" => (g("Float or tile window"), g("Windows")),
        "fullscreen" => (g("Fullscreen"), g("Windows")),
        "fullscreenstate" => (g("Pseudo fullscreen"), g("Windows")),
        "pseudo" => (g("Pseudo tile"), g("Windows")),
        "togglesplit" => (g("Toggle split direction"), g("Windows")),
        "centerwindow" => (g("Center window"), g("Windows")),
        "movefocus" => (format!("Focus window {}", dir(arg)), g("Windows")),
        "movewindow" if arg.is_empty() => (g("Move window (drag)"), g("Windows")),
        "movewindow" => (format!("Move window {}", dir(arg)), g("Windows")),
        "swapwindow" => (format!("Swap window {}", dir(arg)), g("Windows")),
        "resizewindow" => (g("Resize window (drag)"), g("Windows")),
        "resizeactive" => (g("Resize window"), g("Windows")),
        "cyclenext" => (g("Next window"), g("Windows")),
        "workspace" => (format!("Go to workspace {arg}"), g("Workspaces")),
        "movetoworkspace" | "movetoworkspacesilent" => {
            if let Some(name) = arg.strip_prefix("special:") {
                (
                    format!("Send window to the {name} scratchpad"),
                    g("Workspaces"),
                )
            } else {
                (format!("Move window to workspace {arg}"), g("Workspaces"))
            }
        }
        "togglespecialworkspace" => (format!("Toggle the {arg} scratchpad"), g("Workspaces")),
        "submap" if arg == "reset" => (g("Leave resize mode"), g("Resize mode")),
        "submap" => (format!("Enter {arg} mode"), g("Windows")),
        "exit" => (g("Exit Hyprland"), g("System")),
        other => (
            pretty(&format!("{other} {arg}").trim().replace(' ', "-")),
            g("Other"),
        ),
    }
}

fn dir(arg: &str) -> &'static str {
    match arg {
        "l" | "left" => "left",
        "r" | "right" => "right",
        "u" | "up" => "up",
        "d" | "down" => "down",
        _ => "",
    }
}

/// Live binds from `hyprctl binds -j`, labelled from the Lab keymap where an entry exists.
pub fn parse_binds(binds: &Value, keymap: &Value) -> Vec<Bind> {
    let mut labels: HashMap<String, (String, String)> = HashMap::new();
    for e in keymap.as_array().into_iter().flatten() {
        let mods: Vec<String> = e["mods"]
            .as_str()
            .unwrap_or("")
            .split_whitespace()
            .map(str::to_owned)
            .collect();
        if let (Some(key), Some(label), Some(group)) =
            (e["key"].as_str(), e["label"].as_str(), e["group"].as_str())
        {
            labels.insert(canon(&mods, key), (label.to_owned(), group.to_owned()));
        }
    }
    // a mode's binds only work after the bind that enters it, so say which one
    let mut enter: HashMap<String, String> = HashMap::new();
    for b in binds.as_array().into_iter().flatten() {
        let arg = b["arg"].as_str().unwrap_or("");
        if b["dispatcher"] == "submap" && arg != "reset" {
            let mut combo: Vec<String> = mods_from_mask(b["modmask"].as_u64().unwrap_or(0))
                .iter()
                .map(|m| (*m).to_owned())
                .collect();
            combo.push(key_name(b["key"].as_str().unwrap_or(""), 0));
            enter.insert(arg.to_owned(), combo.join(" + "));
        }
    }
    let mut out: Vec<Bind> = Vec::new();
    for b in binds.as_array().into_iter().flatten() {
        let mods = mods_from_mask(b["modmask"].as_u64().unwrap_or(0));
        let key = b["key"].as_str().unwrap_or("");
        let mod_names: Vec<String> = mods.iter().map(|m| (*m).to_owned()).collect();
        let id = canon(&mod_names, key);
        let (label, group) = labels.get(&id).cloned().unwrap_or_else(|| {
            describe(
                b["dispatcher"].as_str().unwrap_or(""),
                b["arg"].as_str().unwrap_or(""),
            )
        });
        let submap = b["submap"].as_str().unwrap_or("");
        let group = if submap.is_empty() {
            group
        } else if let Some(combo) = enter.get(submap) {
            let mut name = submap.to_owned();
            name[..1].make_ascii_uppercase();
            format!("{name} mode, press {combo} first")
        } else {
            "Resize mode".to_owned()
        };
        let mut combo: Vec<String> = mods.iter().map(|m| (*m).to_owned()).collect();
        combo.push(key_name(key, b["keycode"].as_u64().unwrap_or(0)));
        let bind = Bind {
            combo,
            label,
            group,
        };
        if !out.contains(&bind) {
            out.push(bind);
        }
    }
    let rank = |g: &str| {
        GROUP_ORDER
            .iter()
            .position(|o| g.starts_with(o))
            .unwrap_or(GROUP_ORDER.len())
    };
    out.sort_by(|a, b| {
        rank(&a.group)
            .cmp(&rank(&b.group))
            .then_with(|| a.label.cmp(&b.label))
    });
    out
}

struct Data {
    binds: Vec<Bind>,
    health: Vec<(bool, String)>,
}

fn load_data() -> Data {
    let binds = Command::new("hyprctl")
        .args(["binds", "-j"])
        .output()
        .ok()
        .and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok())
        .unwrap_or(Value::Null);
    let health = Command::new("lab")
        .arg("doctor")
        .output()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|l| !l.trim().is_empty())
                .map(|l| {
                    (
                        l.starts_with("ok"),
                        l.split_once(char::is_whitespace)
                            .map_or(l, |x| x.1)
                            .trim()
                            .to_owned(),
                    )
                })
                .collect()
        })
        .unwrap_or_default();
    Data {
        binds: parse_binds(&binds, &read_json("keymap.json")),
        health,
    }
}

pub struct Help {
    win: adw::Window,
    search: gtk::SearchEntry,
    binds: gtk::ListBox,
    rows: RefCell<Vec<Bind>>,
    health: gtk::Box,
    stack: gtk::Stack,
    scrolls: Vec<gtk::ScrolledWindow>,
}

impl Help {
    pub fn new(app: &adw::Application) -> Rc<Self> {
        let win = adw::Window::builder()
            .application(app)
            .title("Kowal Lab help")
            .default_width(980)
            .default_height(720)
            .build();
        win.add_css_class("labd-help");

        let search = gtk::SearchEntry::builder()
            .placeholder_text("Filter keybinds")
            .hexpand(true)
            .build();
        let binds = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .build();
        binds.add_css_class("help-list");
        let binds_scroll = gtk::ScrolledWindow::builder()
            .child(&binds)
            .vexpand(true)
            .build();
        let binds_page = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .build();
        binds_page.add_css_class("help-page");
        binds_page.append(&search);
        binds_page.append(&binds_scroll);

        let features = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(10)
            .build();
        features.add_css_class("help-page");
        build_features(&features, &read_json("help.json"));
        let features_scroll = gtk::ScrolledWindow::builder()
            .child(&features)
            .vexpand(true)
            .build();

        let health = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(6)
            .build();
        health.add_css_class("help-page");
        let health_scroll = gtk::ScrolledWindow::builder()
            .child(&health)
            .vexpand(true)
            .build();

        let stack = gtk::Stack::new();
        stack.add_titled(&binds_page, Some("binds"), "Keybinds");
        stack.add_titled(&features_scroll, Some("features"), "Features");
        stack.add_titled(&health_scroll, Some("health"), "Health");
        let switcher = gtk::StackSwitcher::builder().stack(&stack).build();
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&switcher));
        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&stack));
        win.set_content(Some(&toolbar));

        let me = Rc::new(Help {
            win,
            search,
            binds,
            rows: RefCell::new(Vec::new()),
            health,
            stack,
            scrolls: vec![binds_scroll, features_scroll, health_scroll],
        });
        me.wire();
        me
    }

    fn wire(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.search.connect_search_changed({
            let weak = weak.clone();
            move |_| {
                if let Some(h) = weak.upgrade() {
                    h.binds.invalidate_filter();
                }
            }
        });
        let weak2 = weak.clone();
        self.binds.set_filter_func(move |row| {
            let Some(h) = weak2.upgrade() else {
                return true;
            };
            let q = h.search.text().to_lowercase();
            if q.is_empty() {
                return true;
            }
            let rows = h.rows.borrow();
            let hit = rows.get(row.index() as usize).is_some_and(|b| {
                b.label.to_lowercase().contains(&q)
                    || b.group.to_lowercase().contains(&q)
                    || b.combo.join(" ").to_lowercase().contains(&q)
            });
            hit
        });
        let weak3 = weak.clone();
        self.binds.set_header_func(move |row, before| {
            let Some(h) = weak3.upgrade() else { return };
            let rows = h.rows.borrow();
            let Some(this) = rows.get(row.index() as usize) else {
                return;
            };
            let same = before
                .and_then(|b| rows.get(b.index() as usize))
                .is_some_and(|prev| prev.group == this.group);
            if same {
                row.set_header(None::<&gtk::Widget>);
            } else {
                let l = gtk::Label::builder().label(&this.group).xalign(0.0).build();
                l.add_css_class("help-group");
                row.set_header(Some(&l));
            }
        });
        let keys = gtk::EventControllerKey::new();
        keys.connect_key_pressed({
            let weak = weak.clone();
            move |_, key, _, _| {
                if key == gdk::Key::Escape {
                    if let Some(h) = weak.upgrade() {
                        h.win.set_visible(false);
                    }
                    return glib::Propagation::Stop;
                }
                glib::Propagation::Proceed
            }
        });
        self.win.add_controller(keys);
        // closing hides, so reopening is instant and keeps the app alive
        self.win.connect_close_request(|w| {
            w.set_visible(false);
            glib::Propagation::Stop
        });
    }

    /// `page` is binds, features or health. Asking for the page that is already showing closes the window.
    pub fn toggle(self: &Rc<Self>, page: Option<&str>) {
        let page = page
            .filter(|p| matches!(*p, "binds" | "features" | "health"))
            .unwrap_or("binds");
        if self.win.is_visible() && self.stack.visible_child_name().as_deref() == Some(page) {
            self.win.set_visible(false);
            return;
        }
        self.stack.set_visible_child_name(page);
        self.win.present();
        self.reset_scroll();
        self.search.set_text("");
        self.refresh();
    }

    /// hyprctl and `lab doctor` are slow enough to stall the window, so they run on a worker.
    fn refresh(self: &Rc<Self>) {
        let (tx, rx) = async_channel::bounded::<Data>(1);
        std::thread::spawn(move || {
            let _ = tx.send_blocking(load_data());
        });
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(data) = rx.recv().await else { return };
            if let Some(h) = weak.upgrade() {
                h.show(data);
            }
        });
    }

    fn show(&self, data: Data) {
        while let Some(r) = self.binds.first_child() {
            self.binds.remove(&r);
        }
        *self.rows.borrow_mut() = data.binds.clone();
        for b in &data.binds {
            let row = gtk::Box::builder()
                .orientation(gtk::Orientation::Horizontal)
                .spacing(12)
                .build();
            row.add_css_class("help-row");
            let combo = gtk::Box::builder()
                .orientation(gtk::Orientation::Horizontal)
                .spacing(4)
                .build();
            combo.set_size_request(260, -1);
            for part in &b.combo {
                let k = gtk::Label::new(Some(part));
                k.add_css_class("kbd");
                combo.append(&k);
            }
            row.append(&combo);
            row.append(
                &gtk::Label::builder()
                    .label(&b.label)
                    .xalign(0.0)
                    .hexpand(true)
                    .build(),
            );
            self.binds.append(
                &gtk::ListBoxRow::builder()
                    .child(&row)
                    .activatable(false)
                    .build(),
            );
        }
        self.binds.invalidate_headers();
        self.binds.invalidate_filter();

        while let Some(r) = self.health.first_child() {
            self.health.remove(&r);
        }
        if data.health.is_empty() {
            self.health.append(
                &gtk::Label::builder()
                    .label("lab doctor did not answer")
                    .xalign(0.0)
                    .build(),
            );
        }
        for (ok, line) in data.health {
            let row = gtk::Box::builder()
                .orientation(gtk::Orientation::Horizontal)
                .spacing(12)
                .build();
            let chip = gtk::Label::new(Some(if ok { "OK" } else { "FIX" }));
            chip.add_css_class("kbd");
            chip.add_css_class(if ok { "help-chip-ok" } else { "help-chip-fail" });
            chip.set_size_request(44, -1);
            row.append(&chip);
            let l = gtk::Label::builder()
                .label(friendly(&line))
                .xalign(0.0)
                .wrap(true)
                .hexpand(true)
                .build();
            l.add_css_class(if ok { "help-ok" } else { "help-fail" });
            row.append(&l);
            self.health.append(&row);
        }
        self.reset_scroll();
    }

    fn reset_scroll(&self) {
        for sw in &self.scrolls {
            sw.vadjustment().set_value(0.0);
        }
    }
}

/// `lab doctor` names are for the terminal, the window uses plain ones.
fn friendly(line: &str) -> String {
    const NAMES: &[(&str, &str)] = &[
        ("bus", "Event bus"),
        ("shell services", "Shell"),
        ("continuity services", "Devices and rooms"),
        ("tokens", "Design tokens"),
        ("keymap", "Keymap"),
        (
            "waybar and swaync fallbacks",
            "Fallback bar and notifications",
        ),
        ("sound", "Sound"),
    ];
    NAMES.iter().find(|(k, _)| line.starts_with(k)).map_or_else(
        || line.to_owned(),
        |(k, v)| format!("{v}{}", &line[k.len()..]),
    )
}

fn build_features(page: &gtk::Box, help: &Value) {
    let features = help["features"].as_array().cloned().unwrap_or_default();
    if features.is_empty() {
        page.append(
            &gtk::Label::builder()
                .label("No feature list yet. Switch the config to generate it.")
                .xalign(0.0)
                .build(),
        );
    }
    for f in features {
        let card = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(4)
            .build();
        card.add_css_class("help-card");
        let title = gtk::Label::builder()
            .label(f["title"].as_str().unwrap_or(""))
            .xalign(0.0)
            .build();
        title.add_css_class("help-title");
        card.append(&title);
        card.append(
            &gtk::Label::builder()
                .label(f["text"].as_str().unwrap_or(""))
                .xalign(0.0)
                .wrap(true)
                .build(),
        );
        if let Some(keys) = f["keys"].as_str().filter(|k| !k.is_empty()) {
            let row = gtk::Box::builder()
                .orientation(gtk::Orientation::Horizontal)
                .spacing(4)
                .build();
            for part in keys.split(" + ") {
                let k = gtk::Label::new(Some(part));
                k.add_css_class("kbd");
                row.append(&k);
            }
            card.append(&row);
        }
        page.append(&card);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn mode_binds_name_the_bind_that_enters_them() {
        let binds = json!([
            {"modmask": 64, "key": "R", "dispatcher": "submap", "arg": "resize", "submap": ""},
            {"modmask": 0, "key": "1", "dispatcher": "exec", "arg": "resize-split width 25", "submap": "resize"},
        ]);
        let out = parse_binds(&binds, &Value::Null);
        assert!(
            out.iter()
                .any(|b| b.group == "Resize mode, press SUPER + R first"),
            "{out:?}"
        );
    }

    #[test]
    fn doctor_lines_get_plain_names() {
        assert_eq!(friendly("bus (1 events)"), "Event bus (1 events)");
        assert_eq!(
            friendly("continuity services: lab-inbox is failed"),
            "Devices and rooms: lab-inbox is failed"
        );
        assert_eq!(friendly("something else"), "something else");
    }

    #[test]
    fn modmask_reads_like_a_shortcut() {
        assert_eq!(mods_from_mask(64 | 8), vec!["SUPER", "ALT"]);
        assert_eq!(mods_from_mask(64 | 1 | 2 | 16), vec!["SUPER", "SHIFT"]);
        assert!(mods_from_mask(0).is_empty());
    }

    #[test]
    fn keymap_ids_match_hyprland_ids() {
        let mods = vec!["$mod".to_owned(), "ALT".to_owned()];
        assert_eq!(canon(&mods, "r"), "SUPER+ALT+R");
        let from_mask: Vec<String> = mods_from_mask(64 | 8)
            .iter()
            .map(|m| (*m).to_owned())
            .collect();
        assert_eq!(canon(&from_mask, "R"), canon(&mods, "r"));
    }

    #[test]
    fn labels_for_common_binds() {
        assert_eq!(
            describe("exec", "volume-osd up"),
            ("Volume up".into(), "Media and hardware".into())
        );
        assert_eq!(describe("exec", "kitty").1, "Apps");
        assert_eq!(
            describe("exec", "resize-split width 50").0,
            "Resize to 50% width"
        );
        assert_eq!(
            describe(
                "exec",
                "/nix/store/x-grim/bin/grim -g \"$(slurp)\" - | wl-copy"
            )
            .0,
            "Screenshot a region"
        );
        assert_eq!(
            describe("exec", "bash ~/.config/hypr/scripts/spotlight.sh").0,
            "Spotlight search"
        );
        assert_eq!(describe("exec", "lan-mouse-gui").0, "Mouse sharing");
        assert_eq!(describe("workspace", "3").0, "Go to workspace 3");
        assert_eq!(
            describe("movetoworkspace", "special:minimized").0,
            "Send window to the minimized scratchpad"
        );
        assert_eq!(describe("movefocus", "l").0, "Focus window left");
        assert_eq!(describe("exec", "some-new_tool --flag").0, "Some new tool");
    }

    #[test]
    fn live_binds_use_keymap_labels_first() {
        let keymap =
            json!([{"mods": "$mod", "key": "SPACE", "label": "Command palette", "group": "Shell"}]);
        let binds = json!([
            {"modmask": 64, "key": "SPACE", "dispatcher": "exec", "arg": "lab publish palette.toggle", "submap": ""},
            {"modmask": 64, "key": "Q", "dispatcher": "killactive", "arg": "", "submap": ""},
            {"modmask": 0, "key": "1", "dispatcher": "exec", "arg": "resize-split width 25", "submap": "resize"},
            {"modmask": 64, "key": "Q", "dispatcher": "killactive", "arg": "", "submap": ""},
        ]);
        let out = parse_binds(&binds, &keymap);
        assert_eq!(out.len(), 3, "duplicates collapse");
        assert_eq!(
            out[0],
            Bind {
                combo: vec!["SUPER".into(), "SPACE".into()],
                label: "Command palette".into(),
                group: "Shell".into()
            }
        );
        assert_eq!(out[1].group, "Windows");
        assert_eq!(out[2].group, "Resize mode");
    }
}
