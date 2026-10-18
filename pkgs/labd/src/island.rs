//! The island: one pill at top centre that presents every state change.
//! Events in, one card at a time out. Same-name events update in place (held volume key),
//! `high` priority interrupts, `low` is dropped while busy.

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use gtk::glib;
use gtk4 as gtk;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use libadwaita as adw;
use serde_json::Value;

use crate::glyphs::{self, Glyph};
use crate::motion::Motion;
use crate::tokens::Tokens;

const QUEUE_MAX: usize = 4;
const SLIDE_PX: f64 = 14.0;

#[derive(Clone, PartialEq)]
pub struct Card {
    key: String,
    glyph: Glyph,
    text: String,
    level: Option<f64>,
    hold_ms: u64,
    priority: Priority,
    /// device roster chips: (title, online)
    chips: Vec<(String, bool)>,
}

#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
enum Priority {
    Low,
    Normal,
    High,
}

/// Event to card. Unknown events return None: the island only shows what it was designed to show.
fn card_for(ev: &Value) -> Option<Card> {
    let name = ev["name"].as_str()?;
    let p = &ev["payload"];
    let text_of = |base: &str, key: &str| match p[key].as_str() {
        Some(v) => format!("{base}, {v}"),
        None => base.to_owned(),
    };
    let muted = p["muted"].as_bool().unwrap_or(false);
    let value = p["value"].as_f64();
    let (glyph, text, level, hold_ms) = match name {
        "volume.changed" => {
            let glyph = match (muted, value.unwrap_or(0.0)) {
                (true, _) => Glyph::Muted,
                (_, v) if v < 1.0 => Glyph::Volume(0),
                (_, v) if v < 50.0 => Glyph::Volume(1),
                _ => Glyph::Volume(2),
            };
            let text = if muted { "Muted" } else { "Volume" };
            (glyph, text.to_owned(), value, 1500)
        }
        "mic.changed" => {
            let (glyph, text) = if muted {
                (Glyph::MicOff, "Microphone muted")
            } else {
                (Glyph::Mic, "Microphone active")
            };
            (glyph, text.to_owned(), None, 1800)
        }
        "brightness.changed" => (Glyph::Brightness, "Brightness".to_owned(), value, 1500),
        "focus.on" => (Glyph::FocusOn, "Focus on".to_owned(), None, 2500),
        "focus.failed" => {
            let reason = p["reason"].as_str().unwrap_or("the hub did not answer");
            (
                Glyph::FocusOff,
                format!("Focus unavailable, {reason}"),
                None,
                5000,
            )
        }
        "focus.off" => (Glyph::FocusOff, "Focus off".to_owned(), None, 2500),
        "auth.waiting" => {
            let app = p["app"].as_str().unwrap_or("An app");
            let mut app_chars = app.chars();
            let app = app_chars
                .next()
                .map(|c| c.to_uppercase().chain(app_chars).collect::<String>())
                .unwrap_or_default();
            let host = p["host"].as_str().unwrap_or("this machine");
            (
                Glyph::Fingerprint,
                format!("{app} on {host} is waiting for user authentication"),
                None,
                15000,
            )
        }
        "clipboard.received" => (
            Glyph::Clipboard,
            text_of("Clipboard from", "host").replace("Clipboard from, ", "Clipboard from "),
            None,
            2200,
        ),
        "clipboard.paused" => (
            Glyph::Clipboard,
            "Clipboard sharing paused".to_owned(),
            None,
            2200,
        ),
        "clipboard.resumed" => (
            Glyph::Clipboard,
            "Clipboard sharing on".to_owned(),
            None,
            2200,
        ),
        "auth.done" => {
            let text = if p["ok"].as_bool().unwrap_or(false) {
                "Authenticated"
            } else {
                "Authentication ended"
            };
            (Glyph::Fingerprint, text.to_owned(), None, 1500)
        }
        "theme.changed" => (Glyph::Scene, text_of("Theme", "title"), None, 2500),
        "room.saved" => (Glyph::Room, text_of("Room saved", "name"), None, 2500),
        "room.restored" => (Glyph::Room, text_of("Room restored", "name"), None, 2500),
        "scene.done" => {
            let title = p["title"].as_str().unwrap_or("Scene");
            let failed = p["failed"].as_u64().unwrap_or(0) > 0;
            // scenes whose steps already show their own state stay quiet unless something broke
            if !failed && !p["announce"].as_bool().unwrap_or(true) {
                return None;
            }
            let text = if failed {
                format!("Scene failed, {title}")
            } else {
                title.to_owned()
            };
            (Glyph::Scene, text, None, 2500)
        }
        "handoff.arrived" => (
            Glyph::Handoff,
            text_of("Handoff complete", "peer"),
            None,
            3500,
        ),
        "roster.device" => {
            let title = p["title"].as_str().unwrap_or("Device");
            let state = if p["online"].as_bool().unwrap_or(false) {
                "connected"
            } else {
                "offline"
            };
            (Glyph::Device, format!("{title} {state}"), None, 3000)
        }
        "room.sent" => (
            Glyph::Handoff,
            match p["peer"].as_str() {
                Some(peer) => format!("Room sent to {peer}"),
                None => "Room sent".to_owned(),
            },
            None,
            3000,
        ),
        "room.received" => {
            let name = p["name"].as_str().unwrap_or("room");
            let from = p["from"].as_str().unwrap_or("another device");
            (
                Glyph::Room,
                format!("Room received, {name} from {from}"),
                None,
                8000,
            )
        }
        "battery.target" => (
            Glyph::Battery,
            format!("Charged to {:.0} %", p["value"].as_f64().unwrap_or(0.0)),
            value,
            4000,
        ),
        "battery.low" => (
            Glyph::Battery,
            format!("Battery {:.0} %", p["value"].as_f64().unwrap_or(0.0)),
            value,
            if p["critical"].as_bool().unwrap_or(false) {
                8000
            } else {
                5000
            },
        ),
        "battery.offline_charge" => {
            let place = if p["off"].as_bool().unwrap_or(false) {
                "off"
            } else {
                "asleep"
            };
            (
                Glyph::Battery,
                format!(
                    "Charged {:.0} % to {:.0} % while {place}",
                    p["from"].as_f64().unwrap_or(0.0),
                    p["to"].as_f64().unwrap_or(0.0)
                ),
                None,
                5000,
            )
        }
        "battery.reminder" => {
            let title = p["title"].as_str().unwrap_or("your event");
            let text = match p["kind"].as_str() {
                Some("raise_limit") => format!(
                    "Full charge needed for {title}, the limit is {:.0} %",
                    p["limit"].as_f64().unwrap_or(80.0)
                ),
                _ => format!("Plug in before {title}, the battery will not last it"),
            };
            (Glyph::Battery, text, None, 14000)
        }
        "battery.trip" => {
            let text = match p["state"].as_str() {
                Some("started") if p["scheduled"].as_bool().unwrap_or(false) => {
                    "Charging to full for your schedule"
                }
                Some("started") => "Full charge on",
                _ => "Charge limit restored",
            };
            (Glyph::Battery, text.to_owned(), None, 3000)
        }
        _ => return None,
    };
    let priority = match ev["priority"].as_str() {
        Some("high") => Priority::High,
        Some("low") => Priority::Low,
        _ => Priority::Normal,
    };
    let ttl_ms = (ev["ttl"].as_f64().unwrap_or(30.0) * 1000.0) as u64;
    Some(Card {
        key: name.to_owned(),
        glyph,
        text,
        level: level.map(|v| (v / 100.0).clamp(0.0, 1.0)),
        hold_ms: hold_ms.min(ttl_ms),
        priority,
        chips: Vec::new(),
    })
}

/// roster.changed payload to (title, online), this machine first as the roster publisher sorts it.
fn roster_from(ev: &Value) -> Vec<(String, bool)> {
    ev["payload"]["devices"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|d| {
                    let mut title = d["title"].as_str()?.to_owned();
                    if let Some(pct) = d["battery"]["pct"].as_f64() {
                        title.push_str(&format!(" {pct:.0} %"));
                    }
                    Some((title, d["online"].as_bool().unwrap_or(false)))
                })
                .collect()
        })
        .unwrap_or_default()
}

pub struct Island {
    gap: i32,
    win: gtk::Window,
    pill: gtk::Box,
    icon: gtk::DrawingArea,
    glyph: Rc<Cell<Glyph>>,
    label: gtk::Label,
    bar: gtk::ProgressBar,
    chips_box: gtk::Box,
    /// last roster.changed: (title, online)
    roster: RefCell<Vec<(String, bool)>>,
    motion: Rc<Motion>,
    current: RefCell<Option<Card>>,
    queue: RefCell<VecDeque<Card>>,
    hiding: Cell<bool>,
    generation: Cell<u64>,
}

fn apply(win: &gtk::Window, pill: &gtk::Box, gap: i32, p: f64) {
    pill.set_opacity(p.clamp(0.0, 1.0));
    win.set_margin(Edge::Top, gap + ((p - 1.0) * SLIDE_PX) as i32);
}

impl Island {
    pub fn new(app: &adw::Application, tokens: &Tokens, motion: Rc<Motion>) -> Rc<Self> {
        let win = gtk::Window::builder()
            .application(app)
            .decorated(false)
            .resizable(false)
            .build();
        win.add_css_class("labd-island");
        win.init_layer_shell();
        win.set_namespace(Some("labd-island"));
        win.set_layer(Layer::Overlay);
        win.set_keyboard_mode(KeyboardMode::None);
        win.set_anchor(Edge::Top, true);

        let glyph = Rc::new(Cell::new(Glyph::Room));
        let icon = glyphs::area(&glyph, 22);
        let label = gtk::Label::new(None);
        let bar = gtk::ProgressBar::builder()
            .valign(gtk::Align::Center)
            .width_request(110)
            .build();
        let pill = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(12)
            .build();
        pill.add_css_class("island");
        pill.append(&icon);
        pill.append(&label);
        pill.append(&bar);
        let chips_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(14)
            .build();
        pill.append(&chips_box);
        win.set_child(Some(&pill));

        // the island is output only, clicks must reach whatever is underneath
        win.connect_realize(|w| {
            if let Some(surface) = w.surface() {
                surface.set_input_region(Some(&gtk::cairo::Region::create()));
            }
        });

        apply(&win, &pill, tokens.gap, 0.0);
        Rc::new(Island {
            gap: tokens.gap,
            win,
            pill,
            icon,
            glyph,
            label,
            bar,
            chips_box,
            roster: RefCell::new(Vec::new()),
            motion,
            current: RefCell::new(None),
            queue: RefCell::new(VecDeque::new()),
            hiding: Cell::new(false),
            generation: Cell::new(0),
        })
    }

    pub fn on_event(self: &Rc<Self>, ev: &Value) {
        let card = match ev["name"].as_str() {
            Some("roster.changed") => {
                *self.roster.borrow_mut() = roster_from(ev);
                return;
            }
            Some("roster.show") => self.roster_card(ev),
            _ => card_for(ev),
        };
        let Some(card) = card else { return };
        let idle = self.current.borrow().is_none() || self.hiding.get();
        if idle {
            self.show(card);
            return;
        }
        let same = self
            .current
            .borrow()
            .as_ref()
            .is_some_and(|c| c.key == card.key);
        if same || card.priority == Priority::High {
            self.queue.borrow_mut().clear();
            self.show(card);
        } else if card.priority == Priority::Normal {
            let mut q = self.queue.borrow_mut();
            q.retain(|c| c.key != card.key);
            if q.len() < QUEUE_MAX {
                q.push_back(card);
            }
        }
    }

    fn roster_card(&self, ev: &Value) -> Option<Card> {
        let chips = self.roster.borrow().clone();
        let text = if chips.is_empty() {
            "No devices known"
        } else {
            "Devices"
        };
        Some(Card {
            key: "roster.show".to_owned(),
            glyph: Glyph::Device,
            text: text.to_owned(),
            level: None,
            hold_ms: 4500,
            priority: if ev["priority"] == "high" {
                Priority::High
            } else {
                Priority::Normal
            },
            chips,
        })
    }

    fn show(self: &Rc<Self>, card: Card) {
        while let Some(c) = self.chips_box.first_child() {
            self.chips_box.remove(&c);
        }
        for (title, online) in &card.chips {
            let dot = Rc::new(Cell::new(if *online { Glyph::Dot } else { Glyph::Ring }));
            let chip = gtk::Box::builder()
                .orientation(gtk::Orientation::Horizontal)
                .spacing(6)
                .build();
            chip.append(&glyphs::area(&dot, 10));
            chip.append(&gtk::Label::new(Some(title)));
            chip.set_opacity(if *online { 1.0 } else { 0.5 });
            self.chips_box.append(&chip);
        }
        self.chips_box.set_visible(!card.chips.is_empty());
        self.glyph.set(card.glyph);
        self.icon.queue_draw();
        self.label.set_text(&card.text);
        self.bar.set_visible(card.level.is_some());
        if let Some(level) = card.level {
            self.bar.set_fraction(level);
        }
        let hold = Duration::from_millis(card.hold_ms);
        *self.current.borrow_mut() = Some(card);
        self.hiding.set(false);
        self.win.present();
        if self.motion.progress() < 1.0 {
            self.fade(1.0, || {});
        }

        let gen = self.generation.get() + 1;
        self.generation.set(gen);
        let me = Rc::downgrade(self);
        glib::timeout_add_local_once(hold, move || {
            if let Some(me) = me.upgrade().filter(|m| m.generation.get() == gen) {
                me.advance();
            }
        });
    }

    /// Next queued card morphs in place, otherwise the island leaves.
    fn advance(self: &Rc<Self>) {
        let next = self.queue.borrow_mut().pop_front();
        if let Some(card) = next {
            self.show(card);
            return;
        }
        self.hiding.set(true);
        let me = Rc::downgrade(self);
        self.fade(0.0, move || {
            if let Some(me) = me.upgrade() {
                me.win.set_visible(false);
                *me.current.borrow_mut() = None;
                me.hiding.set(false);
            }
        });
    }

    fn fade(&self, to: f64, on_done: impl Fn() + 'static) {
        let (win, pill, gap) = (self.win.clone(), self.pill.clone(), self.gap);
        self.motion
            .animate(&self.pill, to, move |p| apply(&win, &pill, gap, p), on_done);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn focus_failure_names_the_reason() {
        let ev = json!({"name": "focus.failed", "payload": {"reason": "the hub is unreachable"}, "priority": "high", "ttl": 30});
        let card = card_for(&ev).unwrap();
        assert_eq!(card.text, "Focus unavailable, the hub is unreachable");
        assert_eq!(card.priority, Priority::High);
    }

    #[test]
    fn fingerprint_wait_names_app_and_machine() {
        let ev = json!({"name": "auth.waiting", "payload": {"app": "sudo", "host": "laptop"}, "priority": "high", "ttl": 20});
        let card = card_for(&ev).unwrap();
        assert_eq!(
            card.text,
            "Sudo on laptop is waiting for user authentication"
        );
        let done = card_for(&json!({"name": "auth.done", "payload": {"ok": true}})).unwrap();
        assert_eq!(done.text, "Authenticated");
    }
}
