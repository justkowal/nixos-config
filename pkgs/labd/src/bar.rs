//! The labd bar: workspaces, clock, status and actions in capsules, drawn with the same glyphs, type and
//! spring-free calm as the rest of Lab. Opt in with `lab.bar.enable` (home/lab/bar.nix), Waybar stays the fallback.
//! Modules come from `~/.config/lab/bar.json`: left, center and right are lists of capsules, each a list of modules.

use std::cell::{Cell, RefCell};
use std::io::{BufRead, BufReader};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::thread;
use std::time::Duration;

use adw::prelude::*;
use gtk::glib;
use gtk4 as gtk;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use libadwaita as adw;
use serde_json::Value;

use crate::glyphs::{self, Glyph};
use crate::tray;
use labd::hypr;

pub struct Config {
    visible: bool,
    edge: i32,
    height: i32,
    left: Vec<Vec<String>>,
    center: Vec<Vec<String>>,
    right: Vec<Vec<String>>,
}

fn capsules(v: &Value) -> Vec<Vec<String>> {
    v.as_array()
        .map(|a| {
            a.iter()
                .map(|c| {
                    c.as_array()
                        .map(|m| {
                            m.iter()
                                .filter_map(|n| n.as_str().map(str::to_owned))
                                .collect()
                        })
                        .unwrap_or_default()
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_config(raw: &Value) -> Option<Config> {
    (raw["enable"] == true).then(|| Config {
        visible: raw["visible"].as_bool().unwrap_or(true),
        edge: raw["edge"].as_i64().unwrap_or(12) as i32,
        height: raw["height"].as_i64().unwrap_or(36) as i32,
        left: capsules(&raw["left"]),
        center: capsules(&raw["center"]),
        right: capsules(&raw["right"]),
    })
}

fn load_config() -> Option<Config> {
    let file = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?
        .join("lab/bar.json");
    parse_config(&serde_json::from_str(&std::fs::read_to_string(file).ok()?).ok()?)
}

/// Runs through the compositor so programs live in the session, not in labd's service cgroup.
fn launch(cmd: &str) {
    let cmd = cmd.to_owned();
    thread::spawn(move || {
        let _ = Command::new("hyprctl")
            .args(["dispatch", "exec", &cmd])
            .status();
    });
}

/// Runs `f` on a worker every `every`, hands the result to `apply` on the main loop.
fn poll<T: Send + 'static>(
    every: Duration,
    f: impl Fn() -> T + Send + 'static,
    apply: impl Fn(T) + 'static,
) {
    let (tx, rx) = async_channel::unbounded();
    thread::spawn(move || loop {
        if tx.send_blocking(f()).is_err() {
            break;
        }
        thread::sleep(every);
    });
    glib::spawn_future_local(async move {
        while let Ok(v) = rx.recv().await {
            apply(v);
        }
    });
}

struct Pill {
    root: gtk::Box,
    glyph: Rc<Cell<Glyph>>,
    icon: gtk::DrawingArea,
    label: gtk::Label,
}

impl Pill {
    fn new(glyph: Glyph) -> Rc<Pill> {
        let cell = Rc::new(Cell::new(glyph));
        let icon = glyphs::area(&cell, 16);
        let label = gtk::Label::new(None);
        label.add_css_class("bar-num");
        label.set_visible(false);
        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(6)
            .build();
        root.add_css_class("pill");
        root.append(&icon);
        root.append(&label);
        Rc::new(Pill {
            root,
            glyph: cell,
            icon,
            label,
        })
    }

    fn set(&self, glyph: Glyph, text: &str) {
        self.glyph.set(glyph);
        self.icon.queue_draw();
        self.label.set_text(text);
        self.label.set_visible(!text.is_empty());
    }

    fn on_click(&self, primary: Option<&'static str>, secondary: Option<&'static str>) {
        for (button, cmd) in [(1, primary), (3, secondary)] {
            if let Some(cmd) = cmd {
                let g = gtk::GestureClick::builder().button(button).build();
                g.connect_released(move |_, _, _, _| launch(cmd));
                self.root.add_controller(g);
            }
        }
    }

    fn on_middle(&self, cmd: &'static str) {
        let g = gtk::GestureClick::builder().button(2).build();
        g.connect_released(move |_, _, _, _| launch(cmd));
        self.root.add_controller(g);
    }

    fn on_scroll(&self, up: &'static str, down: &'static str) {
        let c = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
        c.connect_scroll(move |_, _, dy| {
            launch(if dy < 0.0 { up } else { down });
            glib::Propagation::Stop
        });
        self.root.add_controller(c);
    }
}

// ── parsing, kept pure so it can be tested ───────────────────────────────────

/// `Volume: 0.62 [MUTED]` from wpctl.
pub fn parse_wpctl(line: &str) -> Option<(u32, bool)> {
    let value: f64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(((value * 100.0).round() as u32, line.contains("MUTED")))
}

/// 0 to 4 segments from a percentage.
pub fn battery_segments(pct: u32) -> u8 {
    match pct {
        88.. => 4,
        63..=87 => 3,
        38..=62 => 2,
        13..=37 => 1,
        _ => 0,
    }
}

#[derive(Debug, PartialEq, Clone)]
pub enum Net {
    Wifi(u8, String),
    Wired,
    Offline,
}

/// From `nmcli -t -f TYPE,STATE device` and `nmcli -t -f IN-USE,SIGNAL,SSID dev wifi`.
pub fn parse_net(devices: &str, wifi: &str) -> Net {
    let connected = |ty: &str| {
        devices
            .lines()
            .any(|l| l.starts_with(&format!("{ty}:connected")))
    };
    if connected("wifi") {
        let (signal, ssid) = wifi
            .lines()
            .find_map(|l| {
                let mut p = l.splitn(3, ':');
                (p.next()? == "*").then(|| {
                    (
                        p.next().and_then(|s| s.parse::<u32>().ok()).unwrap_or(0),
                        p.next().unwrap_or("").to_owned(),
                    )
                })
            })
            .unwrap_or((0, String::new()));
        let level = match signal {
            67.. => 3,
            34..=66 => 2,
            _ => 1,
        };
        return Net::Wifi(level, ssid);
    }
    if connected("ethernet") {
        return Net::Wired;
    }
    Net::Offline
}

/// swaync `-swb` lines: {"alt":"notification|none|dnd-notification|dnd-none"}.
pub fn bell_for(line: &str) -> Glyph {
    let alt = serde_json::from_str::<Value>(line)
        .ok()
        .and_then(|v| v["alt"].as_str().map(str::to_owned))
        .unwrap_or_default();
    if alt.starts_with("dnd") || alt.starts_with("inhibited") {
        Glyph::BellOff
    } else if alt == "notification" {
        Glyph::BellDot
    } else {
        Glyph::Bell
    }
}

fn read_trim(path: &str) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_owned())
}

fn run(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

// ── modules ──────────────────────────────────────────────────────────────────

type Handler = Box<dyn Fn(&Value)>;

struct Ctx {
    handlers: RefCell<Vec<Handler>>,
}

fn workspaces() -> gtk::Widget {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(2)
        .build();
    let refresh = {
        let row = row.clone();
        Rc::new(move || {
            while let Some(c) = row.first_child() {
                row.remove(&c);
            }
            let active = hypr::active_workspace();
            for w in hypr::workspaces() {
                let b = gtk::Button::with_label(&w.name);
                b.add_css_class("flat");
                b.add_css_class("ws");
                if Some(w.id) == active {
                    b.add_css_class("active");
                }
                let id = w.id;
                b.connect_clicked(move |_| hypr::switch_to(id));
                row.append(&b);
            }
        })
    };
    refresh();
    let (tx, rx) = async_channel::unbounded();
    hypr::follow_events(tx);
    glib::spawn_future_local(async move {
        while rx.recv().await.is_ok() {
            refresh();
        }
    });
    row.upcast()
}

fn clock() -> gtk::Widget {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .build();
    row.add_css_class("pill");
    let time = gtk::Label::new(None);
    time.add_css_class("bar-clock");
    let date = gtk::Label::new(None);
    date.add_css_class("bar-date");
    row.append(&time);
    row.append(&date);
    let tick = move || {
        if let Ok(now) = glib::DateTime::now_local() {
            time.set_text(
                &now.format("%H:%M")
                    .map(|s| s.to_string())
                    .unwrap_or_default(),
            );
            date.set_text(
                &now.format("%d.%m.%Y")
                    .map(|s| s.to_string())
                    .unwrap_or_default(),
            );
        }
    };
    tick();
    glib::timeout_add_seconds_local(1, move || {
        tick();
        glib::ControlFlow::Continue
    });
    row.upcast()
}

fn battery() -> Option<gtk::Widget> {
    let dir = std::fs::read_dir("/sys/class/power_supply")
        .ok()?
        .flatten()
        .map(|e| e.path())
        .find(|p| {
            p.join("capacity").exists()
                && p.file_name()
                    .is_some_and(|n| n.to_string_lossy().starts_with("BAT"))
        })?;
    let pill = Pill::new(Glyph::BatteryLevel(0, false));
    let update = {
        let pill = pill.clone();
        move || {
            let pct: u32 = read_trim(&dir.join("capacity").to_string_lossy())
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            let charging =
                read_trim(&dir.join("status").to_string_lossy()).is_some_and(|s| s == "Charging");
            pill.set(
                Glyph::BatteryLevel(battery_segments(pct), charging),
                &format!("{pct}%"),
            );
            pill.root.set_tooltip_text(Some(&format!(
                "{pct}%{}",
                if charging { ", charging" } else { "" }
            )));
        }
    };
    update();
    glib::timeout_add_seconds_local(15, move || {
        update();
        glib::ControlFlow::Continue
    });
    pill.on_click(Some("accubattery-gui"), Some("control-center-gui"));
    Some(pill.root.clone().upcast())
}

fn network() -> gtk::Widget {
    let pill = Pill::new(Glyph::WifiOff);
    pill.on_click(Some("kitty --class network_tui -e nmtui"), None);
    let p = pill.clone();
    poll(
        Duration::from_secs(8),
        || {
            parse_net(
                &run("nmcli", &["-t", "-f", "TYPE,STATE", "device"]),
                &run("nmcli", &["-t", "-f", "IN-USE,SIGNAL,SSID", "dev", "wifi"]),
            )
        },
        move |n| match n {
            Net::Wifi(level, ssid) => {
                p.set(Glyph::Wifi(level), "");
                p.root.set_tooltip_text(Some(&ssid));
            }
            Net::Wired => {
                p.set(Glyph::Ethernet, "");
                p.root.set_tooltip_text(Some("Wired"));
            }
            Net::Offline => {
                p.set(Glyph::WifiOff, "");
                p.root.set_tooltip_text(Some("No network"));
            }
        },
    );
    pill.root.clone().upcast()
}

fn volume(ctx: &Rc<Ctx>) -> gtk::Widget {
    let pill = Pill::new(Glyph::Volume(2));
    pill.on_click(Some("pwvucontrol"), None);
    pill.on_scroll("volume-osd up", "volume-osd down");
    let show = {
        let pill = pill.clone();
        Rc::new(move |pct: u32, muted: bool| {
            let glyph = match (muted, pct) {
                (true, _) => Glyph::Muted,
                (_, 0) => Glyph::Volume(0),
                (_, 1..=49) => Glyph::Volume(1),
                _ => Glyph::Volume(2),
            };
            pill.set(
                glyph,
                &if muted {
                    "muted".to_owned()
                } else {
                    format!("{pct}%")
                },
            );
        })
    };
    let s = show.clone();
    poll(
        Duration::from_secs(3),
        || parse_wpctl(&run("wpctl", &["get-volume", "@DEFAULT_AUDIO_SINK@"])),
        move |v| {
            if let Some((pct, muted)) = v {
                s(pct, muted);
            }
        },
    );
    ctx.handlers.borrow_mut().push(Box::new(move |ev| {
        if ev["name"] == "volume.changed" {
            show(
                ev["payload"]["value"].as_f64().unwrap_or(0.0).round() as u32,
                ev["payload"]["muted"].as_bool().unwrap_or(false),
            );
        }
    }));
    pill.root.clone().upcast()
}

fn bluetooth() -> gtk::Widget {
    let pill = Pill::new(Glyph::Bluetooth);
    pill.on_click(Some("blueman-manager"), None);
    let p = pill.clone();
    poll(
        Duration::from_secs(10),
        || {
            let on = run("bluetoothctl", &["show"]).contains("Powered: yes");
            let connected = run("bluetoothctl", &["devices", "Connected"])
                .lines()
                .filter(|l| l.starts_with("Device"))
                .count();
            (on, connected)
        },
        move |(on, connected)| {
            p.set(
                Glyph::Bluetooth,
                &if connected > 0 {
                    connected.to_string()
                } else {
                    String::new()
                },
            );
            p.root.set_opacity(if on { 1.0 } else { 0.4 });
            p.root
                .set_tooltip_text(Some(if on { "Bluetooth on" } else { "Bluetooth off" }));
        },
    );
    pill.root.clone().upcast()
}

fn fleet(ctx: &Rc<Ctx>) -> gtk::Widget {
    let pill = Pill::new(Glyph::Device);
    pill.root.set_visible(false);
    pill.on_click(
        Some("fleet-manager-gui"),
        Some("lab publish roster.show --source bar"),
    );
    let p = pill.clone();
    ctx.handlers.borrow_mut().push(Box::new(move |ev| {
        if ev["name"] != "roster.changed" {
            return;
        }
        let devices = ev["payload"]["devices"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let online = devices.iter().filter(|d| d["online"] == true).count();
        p.root.set_visible(!devices.is_empty());
        p.set(Glyph::Device, &format!("{online}/{}", devices.len()));
    }));
    pill.root.clone().upcast()
}

fn focus(ctx: &Rc<Ctx>) -> gtk::Widget {
    let pill = Pill::new(Glyph::FocusOn);
    pill.root.set_visible(false);
    pill.root.add_css_class("accent");
    pill.on_click(Some("focus toggle"), None);
    let until: Rc<Cell<Option<i64>>> = Rc::new(Cell::new(None));
    let render = {
        let (pill, until) = (pill.clone(), until.clone());
        Rc::new(move || {
            let now = glib::real_time() / 1_000_000;
            match until.get().filter(|u| *u > now) {
                Some(u) => {
                    pill.root.set_visible(true);
                    pill.set(Glyph::FocusOn, &format!("{}m", ((u - now) + 59) / 60));
                }
                None => pill.root.set_visible(false),
            }
        })
    };
    let (u, r) = (until.clone(), render.clone());
    poll(
        Duration::from_secs(20),
        || serde_json::from_str::<Value>(&run("focus", &["status"])).ok(),
        move |st| {
            if let Some(st) = st {
                u.set(if st["active"] == true {
                    st["until"].as_i64()
                } else {
                    None
                });
                r();
            }
        },
    );
    let (u, r) = (until.clone(), render.clone());
    ctx.handlers
        .borrow_mut()
        .push(Box::new(move |ev| match ev["name"].as_str() {
            Some("focus.on") => {
                let minutes = ev["payload"]["minutes"]
                    .as_str()
                    .and_then(|m| m.parse::<i64>().ok())
                    .unwrap_or(25);
                u.set(Some(glib::real_time() / 1_000_000 + minutes * 60));
                r();
            }
            Some("focus.off") => {
                u.set(None);
                r();
            }
            _ => {}
        }));
    glib::timeout_add_seconds_local(30, move || {
        render();
        glib::ControlFlow::Continue
    });
    pill.root.clone().upcast()
}

fn notifications() -> gtk::Widget {
    let pill = Pill::new(Glyph::Bell);
    pill.on_click(Some("swaync-client -t -sw"), Some("swaync-client -d -sw"));
    let (tx, rx) = async_channel::unbounded::<Glyph>();
    thread::spawn(move || loop {
        let mut cmd = Command::new("swaync-client");
        cmd.arg("-swb").stdout(Stdio::piped()).stderr(Stdio::null());
        unsafe {
            cmd.pre_exec(|| {
                // labd restarts must not leave the watcher running
                unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) };
                Ok(())
            });
        }
        if let Ok(mut child) = cmd.spawn() {
            if let Some(out) = child.stdout.take() {
                for line in BufReader::new(out).lines().map_while(Result::ok) {
                    if tx.send_blocking(bell_for(&line)).is_err() {
                        return;
                    }
                }
            }
            let _ = child.wait();
        }
        thread::sleep(Duration::from_secs(3));
    });
    let p = pill.clone();
    glib::spawn_future_local(async move {
        while let Ok(g) = rx.recv().await {
            p.set(g, "");
        }
    });
    pill.root.clone().upcast()
}

fn action(glyph: Glyph, cmd: &'static str, tip: &str) -> gtk::Widget {
    let pill = Pill::new(glyph);
    pill.on_click(Some(cmd), None);
    pill.root.set_tooltip_text(Some(tip));
    pill.root.clone().upcast()
}

/// Waybar glyphs live in the private use area; the Lab bar draws its own, so drop them.
pub fn clean_text(raw: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    for c in raw.chars() {
        match c {
            '<' => in_tag = true,
            '>' if in_tag => in_tag = false,
            _ if in_tag => {}
            '\u{e000}'..='\u{f8ff}' | '\u{f0000}'..='\u{ffffd}' => {}
            _ => out.push(c),
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Quiet classes leave the capsule neutral; anything else (running, active) takes the accent.
pub fn is_accent(class: &str) -> bool {
    !class.split_whitespace().all(|c| {
        matches!(
            c,
            "idle" | "inactive" | "online" | "normal" | "off" | "disconnected" | "none" | ""
        )
    })
}

/// A module backed by a command that prints one Waybar style JSON object per run.
fn exec(
    glyph: Glyph,
    cmd: &'static str,
    secs: u64,
    clicks: [Option<&'static str>; 3],
) -> gtk::Widget {
    let pill = Pill::new(glyph);
    // stays hidden until the command works, so thinkdot never shows on a machine without it
    pill.root.set_visible(false);
    pill.on_click(clicks[0], clicks[2]);
    if let Some(m) = clicks[1] {
        pill.on_middle(m);
    }
    let p = pill.clone();
    poll(
        Duration::from_secs(secs),
        move || {
            let mut parts = cmd.split_whitespace();
            let prog = parts.next().unwrap_or_default();
            let args: Vec<&str> = parts.collect();
            serde_json::from_str::<Value>(&run(prog, &args)).ok()
        },
        move |v| {
            let Some(v) = v else { return };
            p.root.set_visible(true);
            p.set(glyph, &clean_text(v["text"].as_str().unwrap_or_default()));
            let tip = v["tooltip"].as_str().map(clean_text_keep_lines);
            p.root.set_tooltip_text(tip.as_deref());
            let class = v["class"].as_str().unwrap_or_default();
            if is_accent(class) {
                p.root.add_css_class("accent");
            } else {
                p.root.remove_css_class("accent");
            }
        },
    );
    pill.root.clone().upcast()
}

fn clean_text_keep_lines(raw: &str) -> String {
    raw.lines().map(clean_text).collect::<Vec<_>>().join("\n")
}

/// Panel brightness from sysfs. None on machines without a backlight.
fn backlight() -> Option<gtk::Widget> {
    let dir = std::fs::read_dir("/sys/class/backlight")
        .ok()?
        .flatten()
        .next()?
        .path();
    let read = move |f: &str| -> Option<f64> {
        std::fs::read_to_string(dir.join(f))
            .ok()?
            .trim()
            .parse()
            .ok()
    };
    let pill = Pill::new(Glyph::Brightness);
    pill.on_scroll("brightness-osd up", "brightness-osd down");
    let p = pill.clone();
    poll(
        Duration::from_secs(2),
        move || Some((read("brightness")? / read("max_brightness")? * 100.0).round() as u32),
        move |v| {
            if let Some(v) = v {
                p.set(Glyph::Brightness, &format!("{v}%"));
            }
        },
    );
    Some(pill.root.clone().upcast())
}

/// Current track from playerctl, hidden while nothing plays.
fn media() -> gtk::Widget {
    let pill = Pill::new(Glyph::Note);
    pill.root.set_visible(false);
    pill.root.add_css_class("media");
    pill.on_click(Some("playerctl play-pause"), Some("playerctl next"));
    pill.on_middle("playerctl previous");
    let p = pill.clone();
    poll(
        Duration::from_secs(3),
        || {
            run(
                "playerctl",
                &["metadata", "--format", "{{status}}|{{artist}} - {{title}}"],
            )
        },
        move |out| match out.trim().split_once('|') {
            Some((status, title))
                if status != "Stopped" && !title.trim_matches(&[' ', '-'][..]).is_empty() =>
            {
                let mut t: String = title.chars().take(36).collect();
                if title.chars().count() > 36 {
                    t.push('…');
                }
                p.root.set_visible(true);
                p.set(Glyph::Note, &t);
            }
            _ => p.root.set_visible(false),
        },
    );
    pill.root.clone().upcast()
}

fn module(name: &str, ctx: &Rc<Ctx>) -> Option<gtk::Widget> {
    Some(match name {
        "pomodoro" => exec(
            Glyph::Timer,
            "pomodoro status",
            1,
            [
                Some("pomodoro toggle"),
                Some("pomodoro reset"),
                Some("pomodoro skip"),
            ],
        ),
        "caffeine" => exec(
            Glyph::Cup,
            "caffeine waybar",
            2,
            [Some("caffeine toggle"), None, None],
        ),
        "thinkdot" => exec(
            Glyph::Dial,
            "thinkdot waybar",
            2,
            [
                Some("thinkdot stealth toggle"),
                Some("thinkdot gauge"),
                Some("control-center-gui"),
            ],
        ),
        "backlight" => backlight()?,
        "media" => media(),
        "workspaces" => workspaces(),
        "clock" => clock(),
        "battery" => battery()?,
        "network" => network(),
        "volume" => volume(ctx),
        "bluetooth" => bluetooth(),
        "fleet" => fleet(ctx),
        "focus" => focus(ctx),
        "notifications" => notifications(),
        "control" => action(Glyph::Sliders, "control-center-gui", "Control center"),
        "power" => action(Glyph::Power, "power-menu", "Power"),
        "tray" => tray::widget(),
        _ => return None,
    })
}

/// A capsule shows only while at least one of its modules does.
fn sync_capsule(capsule: &gtk::Box) {
    let mut child = capsule.first_child();
    while let Some(w) = child {
        if w.is_visible() {
            capsule.set_visible(true);
            return;
        }
        child = w.next_sibling();
    }
    capsule.set_visible(false);
}

fn section(caps: &[Vec<String>], ctx: &Rc<Ctx>) -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(0)
        .build();
    for cap in caps {
        let capsule = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(0)
            .build();
        capsule.add_css_class("cap");
        for name in cap {
            if let Some(w) = module(name, ctx) {
                let c = capsule.clone();
                w.connect_visible_notify(move |_| sync_capsule(&c));
                capsule.append(&w);
            }
        }
        // a capsule whose modules all dropped out (no battery on a desktop) is not drawn
        if capsule.first_child().is_some() {
            sync_capsule(&capsule);
            row.append(&capsule);
        }
    }
    row
}

pub struct Bar {
    ctx: Rc<Ctx>,
    win: gtk::Window,
}

impl Bar {
    /// None unless bar.json enables it.
    pub fn new(app: &adw::Application) -> Option<Rc<Bar>> {
        let cfg = load_config()?;
        let ctx = Rc::new(Ctx {
            handlers: RefCell::new(Vec::new()),
        });
        let win = gtk::Window::builder()
            .application(app)
            .decorated(false)
            .build();
        win.add_css_class("labd-bar");
        win.init_layer_shell();
        win.set_namespace(Some("labd-bar"));
        win.set_layer(Layer::Top);
        win.set_keyboard_mode(KeyboardMode::None);
        for e in [Edge::Top, Edge::Left, Edge::Right] {
            win.set_anchor(e, true);
            win.set_margin(e, cfg.edge);
        }
        win.auto_exclusive_zone_enable();

        let root = gtk::CenterBox::new();
        root.add_css_class("lab-bar");
        root.set_height_request(cfg.height);
        root.set_start_widget(Some(&section(&cfg.left, &ctx)));
        root.set_center_widget(Some(&section(&cfg.center, &ctx)));
        root.set_end_widget(Some(&section(&cfg.right, &ctx)));
        win.set_child(Some(&root));
        win.set_visible(cfg.visible);
        Some(Rc::new(Bar { ctx, win }))
    }

    pub fn on_event(&self, ev: &Value) {
        match ev["name"].as_str() {
            Some("bar.show") => self.win.set_visible(true),
            Some("bar.hide") => self.win.set_visible(false),
            Some("bar.toggle") => self.win.set_visible(!self.win.is_visible()),
            _ => {}
        }
        for h in self.ctx.handlers.borrow().iter() {
            h(ev);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn config_is_off_unless_enabled() {
        assert!(parse_config(&json!({"enable": false})).is_none());
        assert!(parse_config(&Value::Null).is_none());
        let c = parse_config(&json!({"enable": true, "edge": 8, "height": 32, "left": [["workspaces"]], "center": [["clock"]], "right": [["battery", "network"], ["power"]]})).unwrap();
        assert_eq!((c.edge, c.height), (8, 32));
        assert_eq!(
            c.right,
            vec![
                vec!["battery".to_owned(), "network".to_owned()],
                vec!["power".to_owned()]
            ]
        );
    }

    #[test]
    fn waybar_text_loses_icons_and_markup() {
        assert_eq!(clean_text("\u{f0ff4} 24:59"), "24:59");
        assert_eq!(clean_text("<span>a</span>  b"), "a b");
        assert_eq!(clean_text("\u{f04b2}"), "");
        assert!(is_accent("work"));
        assert!(!is_accent("inactive"));
        assert!(!is_accent(""));
    }

    #[test]
    fn wpctl_lines_parse() {
        assert_eq!(parse_wpctl("Volume: 0.62"), Some((62, false)));
        assert_eq!(parse_wpctl("Volume: 1.10 [MUTED]"), Some((110, true)));
        assert_eq!(parse_wpctl("garbage"), None);
        assert_eq!(parse_wpctl(""), None);
    }

    #[test]
    fn battery_levels() {
        assert_eq!(battery_segments(100), 4);
        assert_eq!(battery_segments(70), 3);
        assert_eq!(battery_segments(50), 2);
        assert_eq!(battery_segments(20), 1);
        assert_eq!(battery_segments(5), 0);
    }

    #[test]
    fn network_states() {
        let dev = "wifi:connected\nethernet:unavailable\nloopback:unmanaged\n";
        let wifi = " :20:cafe\n*:72:home-net\n :50:other\n";
        assert_eq!(parse_net(dev, wifi), Net::Wifi(3, "home-net".into()));
        assert_eq!(
            parse_net("ethernet:connected\nwifi:disconnected\n", ""),
            Net::Wired
        );
        assert_eq!(parse_net("wifi:disconnected\n", ""), Net::Offline);
        assert_eq!(
            parse_net("wifi:connected\n", "*:40:x\n"),
            Net::Wifi(2, "x".into())
        );
    }

    #[test]
    fn bell_follows_swaync_state() {
        assert_eq!(bell_for(r#"{"alt":"notification"}"#), Glyph::BellDot);
        assert_eq!(bell_for(r#"{"alt":"none"}"#), Glyph::Bell);
        assert_eq!(bell_for(r#"{"alt":"dnd-notification"}"#), Glyph::BellOff);
        assert_eq!(bell_for("not json"), Glyph::Bell);
    }
}
