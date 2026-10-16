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

use crate::tokens::Tokens;

const QUEUE_MAX: usize = 4;
const SLIDE_PX: f64 = 14.0;

#[derive(Clone, PartialEq)]
pub struct Card {
    key: String,
    icon: &'static str,
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
/// Icons are Adwaita symbolic names until the Lucide set from the tokens ships.
fn card_for(ev: &Value) -> Option<Card> {
    let name = ev["name"].as_str()?;
    let p = &ev["payload"];
    let text_of = |base: &str, key: &str| match p[key].as_str() {
        Some(v) => format!("{base}, {v}"),
        None => base.to_owned(),
    };
    let (icon, text, level, hold_ms) = match name {
        "volume.changed" => {
            let muted = p["muted"].as_bool().unwrap_or(false);
            let icon = if muted {
                "audio-volume-muted-symbolic"
            } else {
                "audio-volume-high-symbolic"
            };
            (
                icon,
                if muted {
                    "Muted".to_owned()
                } else {
                    "Volume".to_owned()
                },
                p["value"].as_f64(),
                1500,
            )
        }
        "brightness.changed" => (
            "display-brightness-symbolic",
            "Brightness".to_owned(),
            p["value"].as_f64(),
            1500,
        ),
        "focus.on" => (
            "weather-clear-night-symbolic",
            "Focus on".to_owned(),
            None,
            2500,
        ),
        "focus.off" => (
            "weather-clear-night-symbolic",
            "Focus off".to_owned(),
            None,
            2500,
        ),
        "room.saved" => (
            "view-grid-symbolic",
            text_of("Room saved", "name"),
            None,
            2500,
        ),
        "room.restored" => (
            "view-grid-symbolic",
            text_of("Room restored", "name"),
            None,
            2500,
        ),
        "handoff.arrived" => (
            "emblem-synchronizing-symbolic",
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
        icon,
        text,
        level: level.map(|v| (v / 100.0).clamp(0.0, 1.0)),
        hold_ms: hold_ms.min(ttl_ms),
        priority,
    })
}

pub struct Island {
    tokens: Tokens,
    win: gtk::Window,
    pill: gtk::Box,
    icon: gtk::Image,
    label: gtk::Label,
    bar: gtk::ProgressBar,
    current: RefCell<Option<Card>>,
    queue: RefCell<VecDeque<Card>>,
    hiding: Cell<bool>,
    generation: Cell<u64>,
    progress: Cell<f64>,
    anim: RefCell<Option<adw::SpringAnimation>>,
}

impl Island {
    pub fn new(app: &adw::Application, tokens: Tokens) -> Rc<Self> {
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

        let icon = gtk::Image::builder().pixel_size(20).build();
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

        let island = Rc::new(Island {
            tokens,
            win,
            pill,
            icon,
            label,
            bar,
            current: RefCell::new(None),
            queue: RefCell::new(VecDeque::new()),
            hiding: Cell::new(false),
            generation: Cell::new(0),
            progress: Cell::new(0.0),
            anim: RefCell::new(None),
        });
        island.set_progress(0.0);
        island
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
        self.icon.set_icon_name(Some(card.icon));
        self.label.set_text(&card.text);
        self.bar.set_visible(card.level.is_some());
        if let Some(level) = card.level {
            self.bar.set_fraction(level);
        }
        let hold = Duration::from_millis(card.hold_ms);
        *self.current.borrow_mut() = Some(card);
        self.hiding.set(false);
        self.win.present();
        if self.progress.get() < 1.0 {
            self.animate(1.0, || {});
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
        self.animate(0.0, move || {
            if let Some(me) = me.upgrade() {
                me.win.set_visible(false);
                *me.current.borrow_mut() = None;
                me.hiding.set(false);
            }
        });
    }

    fn set_progress(&self, p: f64) {
        self.progress.set(p);
        self.pill.set_opacity(p.clamp(0.0, 1.0));
        self.win
            .set_margin(Edge::Top, self.tokens.gap + ((p - 1.0) * SLIDE_PX) as i32);
    }

    fn animate(self: &Rc<Self>, to: f64, on_done: impl Fn() + 'static) {
        // pausing the old animation drops its done callback, which is what we want when interrupted
        if let Some(old) = self.anim.borrow_mut().take() {
            old.pause();
        }
        if self.tokens.reduced_motion {
            self.set_progress(to);
            on_done();
            return;
        }
        let me = Rc::downgrade(self);
        let target = adw::CallbackAnimationTarget::new(move |v| {
            if let Some(me) = me.upgrade() {
                me.set_progress(v);
            }
        });
        let params = adw::SpringParams::new(
            self.tokens.damping_ratio(),
            self.tokens.mass,
            self.tokens.stiffness,
        );
        let anim = adw::SpringAnimation::new(&self.pill, self.progress.get(), to, params, target);
        anim.set_epsilon(0.002);
        anim.connect_done(move |_| on_done());
        anim.play();
        *self.anim.borrow_mut() = Some(anim);
    }
}
