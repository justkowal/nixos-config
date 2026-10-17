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
}

#[derive(Clone, Copy, PartialEq, PartialOrd)]
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
        "focus.off" => (Glyph::FocusOff, "Focus off".to_owned(), None, 2500),
        "room.saved" => (Glyph::Room, text_of("Room saved", "name"), None, 2500),
        "room.restored" => (Glyph::Room, text_of("Room restored", "name"), None, 2500),
        "handoff.arrived" => (
            Glyph::Handoff,
            text_of("Handoff complete", "peer"),
            None,
            3500,
        ),
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
    })
}

pub struct Island {
    gap: i32,
    win: gtk::Window,
    pill: gtk::Box,
    icon: gtk::DrawingArea,
    glyph: Rc<Cell<Glyph>>,
    label: gtk::Label,
    bar: gtk::ProgressBar,
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
            motion,
            current: RefCell::new(None),
            queue: RefCell::new(VecDeque::new()),
            hiding: Cell::new(false),
            generation: Cell::new(0),
        })
    }

    pub fn on_event(self: &Rc<Self>, ev: &Value) {
        let Some(card) = card_for(ev) else { return };
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

    fn show(self: &Rc<Self>, card: Card) {
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
