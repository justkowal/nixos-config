//! The command palette: one keyboard surface for actions, rooms and apps.
//! Static entries come from ~/.config/lab/palette.json (home/lab/palette.nix), rooms from
//! `room entries`, apps from the desktop entries. Everything runs through `hyprctl dispatch exec`
//! so launched programs live in the compositor's session, not in labd's service cgroup.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::process::Command;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gdk, gio, glib};
use gtk4 as gtk;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use libadwaita as adw;
use serde_json::Value;

use crate::glyphs::{self, Glyph};
use crate::motion::Motion;
use crate::tokens::Tokens;

const MARGIN_TOP: i32 = 120;
const SLIDE_PX: f64 = 16.0;
const MAX_ROWS: usize = 40;

#[derive(Clone)]
struct Item {
    title: String,
    group: String,
    exec: String,
    confirm: bool,
    glyph: Glyph,
    icon: Option<gio::Icon>,
    /// lower sorts first on equal score: actions, rooms, apps
    rank: u8,
}

fn glyph_named(name: &str) -> Glyph {
    match name {
        "focus" => Glyph::FocusOn,
        "room" => Glyph::Room,
        "power" => Glyph::Power,
        "lock" => Glyph::Lock,
        "handoff" => Glyph::Handoff,
        "search" => Glyph::Search,
        "scene" => Glyph::Scene,
        "brightness" => Glyph::Brightness,
        _ => Glyph::Action,
    }
}

fn config_file(name: &str) -> Option<PathBuf> {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .map(|d| d.join("lab").join(name))
}

fn palette_json() -> Value {
    config_file("palette.json")
        .and_then(|f| std::fs::read_to_string(f).ok())
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .unwrap_or(Value::Null)
}

const DEFAULT_SEARCH: &str = "https://www.google.com/search?q=%s";

/// Percent-encodes everything outside the RFC 3986 unreserved set.
fn url_encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                char::from(b).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn web_item(term: &str, template: &str) -> Item {
    let url = template.replace("%s", &url_encode(term));
    Item {
        title: format!("Search the web for \"{term}\""),
        group: "Web".into(),
        exec: format!("xdg-open {}", shell_quote(&url)),
        confirm: false,
        glyph: Glyph::Search,
        icon: None,
        rank: 3,
    }
}

fn static_items(raw: &Value) -> Vec<Item> {
    raw["entries"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|e| {
                    Some(Item {
                        title: e["title"].as_str()?.to_owned(),
                        group: e["group"].as_str().unwrap_or("Action").to_owned(),
                        exec: e["exec"].as_str()?.to_owned(),
                        confirm: e["confirm"].as_bool().unwrap_or(false),
                        glyph: glyph_named(e["glyph"].as_str().unwrap_or("")),
                        icon: None,
                        rank: 0,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

fn app_items() -> Vec<Item> {
    gio::AppInfo::all()
        .into_iter()
        .filter(|a| a.should_show())
        .filter_map(|a| {
            let path = a.downcast_ref::<gio_unix::DesktopAppInfo>()?.filename()?;
            Some(Item {
                title: a.display_name().to_string(),
                group: "App".into(),
                exec: format!("gio launch {}", shell_quote(&path.to_string_lossy())),
                confirm: false,
                glyph: Glyph::Action,
                icon: a.icon(),
                rank: 2,
            })
        })
        .collect()
}

/// `room entries` prints [{title, group, exec, rank}]; it is slow (scans ~ for repos), so it runs off the main loop.
fn room_items(entries: &Value) -> Vec<Item> {
    entries
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|e| {
                    let group = e["group"].as_str().unwrap_or("Room");
                    Some(Item {
                        title: e["title"].as_str()?.to_owned(),
                        group: group.to_owned(),
                        exec: e["exec"].as_str()?.to_owned(),
                        confirm: false,
                        glyph: if matches!(group, "Inbox" | "Send") {
                            Glyph::Handoff
                        } else {
                            Glyph::Room
                        },
                        icon: None,
                        rank: e["rank"].as_u64().map_or(1, |r| r.min(3) as u8),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Subsequence match with bonuses for word starts and runs. None if the query is not contained.
fn fuzzy(query: &[char], text: &str) -> Option<i32> {
    let t: Vec<char> = text.chars().flat_map(char::to_lowercase).collect();
    let (mut ti, mut score, mut prev) = (0, 0i32, None::<usize>);
    for &qc in query {
        let i = loop {
            if ti >= t.len() {
                return None;
            }
            ti += 1;
            if t[ti - 1] == qc {
                break ti - 1;
            }
        };
        score += 10;
        if i == 0 || !t[i - 1].is_alphanumeric() {
            score += 15;
        }
        match prev {
            Some(p) if p + 1 == i => score += 12,
            Some(p) => score -= (i - p - 1).min(8) as i32,
            None => score -= i.min(8) as i32,
        }
        prev = Some(i);
    }
    Some(score - (t.len() as i32) / 4)
}

pub struct Palette {
    win: gtk::Window,
    panel: gtk::Box,
    entry: gtk::Entry,
    list: gtk::ListBox,
    scroll: gtk::ScrolledWindow,
    motion: Rc<Motion>,
    items: RefCell<Vec<Item>>,
    search_url: RefCell<String>,
    shown: RefCell<Vec<usize>>,
    pending: Cell<Option<usize>>,
    open: Cell<bool>,
}

fn apply(win: &gtk::Window, panel: &gtk::Box, p: f64) {
    panel.set_opacity(p.clamp(0.0, 1.0));
    win.set_margin(Edge::Top, MARGIN_TOP + ((p - 1.0) * SLIDE_PX) as i32);
}

impl Palette {
    pub fn new(app: &adw::Application, _tokens: &Tokens, motion: Rc<Motion>) -> Rc<Self> {
        let win = gtk::Window::builder()
            .application(app)
            .decorated(false)
            .resizable(false)
            .build();
        win.add_css_class("labd-palette");
        win.init_layer_shell();
        win.set_namespace(Some("labd-palette"));
        win.set_layer(Layer::Overlay);
        win.set_keyboard_mode(KeyboardMode::Exclusive);
        win.set_anchor(Edge::Top, true);

        let entry = gtk::Entry::builder()
            .placeholder_text("Search apps, rooms, actions")
            .hexpand(true)
            .build();
        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::Single)
            .activate_on_single_click(true)
            .build();
        let scroll = gtk::ScrolledWindow::builder()
            .child(&list)
            .propagate_natural_height(true)
            .max_content_height(420)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();
        let panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .width_request(640)
            .build();
        panel.add_css_class("palette");
        panel.append(&entry);
        panel.append(&scroll);
        win.set_child(Some(&panel));
        apply(&win, &panel, 0.0);

        let me = Rc::new(Palette {
            win,
            panel,
            entry,
            list,
            scroll,
            motion,
            items: RefCell::new(Vec::new()),
            search_url: RefCell::new(DEFAULT_SEARCH.to_owned()),
            shown: RefCell::new(Vec::new()),
            pending: Cell::new(None),
            open: Cell::new(false),
        });
        me.wire();
        me
    }

    fn wire(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.entry.connect_changed({
            let weak = weak.clone();
            move |_| {
                if let Some(p) = weak.upgrade() {
                    p.pending.set(None);
                    p.refresh();
                }
            }
        });
        self.entry.connect_activate({
            let weak = weak.clone();
            move |_| {
                if let Some(p) = weak.upgrade() {
                    p.run_selected();
                }
            }
        });
        self.list.connect_row_activated({
            let weak = weak.clone();
            move |_, row| {
                if let Some(p) = weak.upgrade() {
                    p.list.select_row(Some(row));
                    p.run_selected();
                }
            }
        });
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        keys.connect_key_pressed({
            let weak = weak.clone();
            move |_, key, _, state| {
                let Some(p) = weak.upgrade() else {
                    return glib::Propagation::Proceed;
                };
                let ctrl = state.contains(gdk::ModifierType::CONTROL_MASK);
                match key {
                    gdk::Key::Escape => p.close(),
                    gdk::Key::Down => p.step(1),
                    gdk::Key::Up => p.step(-1),
                    gdk::Key::n if ctrl => p.step(1),
                    gdk::Key::p if ctrl => p.step(-1),
                    _ => return glib::Propagation::Proceed,
                }
                glib::Propagation::Stop
            }
        });
        self.win.add_controller(keys);
        self.win.connect_is_active_notify({
            let weak = weak.clone();
            move |w| {
                if let Some(p) = weak.upgrade() {
                    if p.open.get() && !w.is_active() && p.motion.progress() >= 1.0 {
                        p.close();
                    }
                }
            }
        });
    }

    pub fn toggle(self: &Rc<Self>) {
        if self.open.get() {
            self.close();
        } else {
            self.open();
        }
    }

    fn open(self: &Rc<Self>) {
        let raw = palette_json();
        *self.search_url.borrow_mut() = raw["search"].as_str().unwrap_or(DEFAULT_SEARCH).to_owned();
        let mut items = static_items(&raw);
        items.extend(app_items());
        *self.items.borrow_mut() = items;
        self.pending.set(None);
        self.entry.set_text("");
        self.refresh();
        self.open.set(true);
        self.win.present();
        self.entry.grab_focus();
        self.fade(1.0, || {});

        let (tx, rx) = async_channel::bounded::<Value>(1);
        std::thread::spawn(move || {
            let out = Command::new("room").arg("entries").output().ok();
            let parsed = out.and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok());
            let _ = tx.send_blocking(parsed.unwrap_or(Value::Null));
        });
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(entries) = rx.recv().await else { return };
            if let Some(p) = weak.upgrade().filter(|p| p.open.get()) {
                p.items.borrow_mut().extend(room_items(&entries));
                p.refresh();
            }
        });
    }

    fn close(self: &Rc<Self>) {
        if !self.open.replace(false) {
            return;
        }
        let win = self.win.clone();
        self.fade(0.0, move || win.set_visible(false));
    }

    fn fade(&self, to: f64, on_done: impl Fn() + 'static) {
        let (win, panel) = (self.win.clone(), self.panel.clone());
        self.motion
            .animate(&self.panel, to, move |p| apply(&win, &panel, p), on_done);
    }

    fn refresh(&self) {
        let query: Vec<char> = self
            .entry
            .text()
            .chars()
            .flat_map(char::to_lowercase)
            .collect();
        {
            // the web row follows the typed text and always ranks last, so it only wins when nothing else matches
            let mut items = self.items.borrow_mut();
            items.retain(|it| it.group != "Web");
            let text = self.entry.text();
            let term = text.trim();
            if !term.is_empty() {
                items.push(web_item(term, &self.search_url.borrow()));
            }
        }
        let items = self.items.borrow();
        let mut hits: Vec<(i32, usize)> = items
            .iter()
            .enumerate()
            .filter(|(_, it)| query.is_empty() && it.rank < 2 || !query.is_empty())
            .filter_map(|(i, it)| {
                let base = if it.group == "Web" {
                    Some(-1000)
                } else if query.is_empty() {
                    Some(0)
                } else {
                    fuzzy(&query, &it.title)
                }?;
                Some((base - i32::from(it.rank) * 4, i))
            })
            .collect();
        if !query.is_empty() {
            hits.sort_by_key(|h| std::cmp::Reverse(h.0));
        }
        hits.truncate(MAX_ROWS);
        let shown: Vec<usize> = hits.into_iter().map(|(_, i)| i).collect();

        while let Some(row) = self.list.first_child() {
            self.list.remove(&row);
        }
        for &i in &shown {
            self.list
                .append(&self.row(&items[i], self.pending.get() == Some(i)));
        }
        if shown.is_empty() {
            let msg = gtk::Label::builder()
                .label("No results")
                .xalign(0.0)
                .build();
            msg.add_css_class("empty");
            self.list.append(
                &gtk::ListBoxRow::builder()
                    .child(&msg)
                    .selectable(false)
                    .activatable(false)
                    .build(),
            );
        } else if let Some(first) = self.list.row_at_index(0) {
            self.list.select_row(Some(&first));
        }
        *self.shown.borrow_mut() = shown;
    }

    fn row(&self, item: &Item, confirming: bool) -> gtk::ListBoxRow {
        let b = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(12)
            .build();
        match &item.icon {
            Some(icon) => b.append(&gtk::Image::builder().gicon(icon).pixel_size(22).build()),
            None => b.append(&glyphs::area(&Rc::new(Cell::new(item.glyph)), 22)),
        }
        let title = if confirming {
            format!("Confirm: {}", item.title)
        } else {
            item.title.clone()
        };
        b.append(
            &gtk::Label::builder()
                .label(title)
                .xalign(0.0)
                .hexpand(true)
                .ellipsize(gtk::pango::EllipsizeMode::End)
                .build(),
        );
        let group = gtk::Label::new(Some(if confirming {
            "Enter to confirm"
        } else {
            &item.group
        }));
        group.add_css_class("dim");
        b.append(&group);
        gtk::ListBoxRow::builder().child(&b).build()
    }

    fn step(&self, delta: i32) {
        let n = self.shown.borrow().len() as i32;
        if n == 0 {
            return;
        }
        let cur = self.list.selected_row().map_or(0, |r| r.index());
        let next = (cur + delta).rem_euclid(n);
        let Some(row) = self.list.row_at_index(next) else {
            return;
        };
        self.list.select_row(Some(&row));
        // keep the selection in view without moving keyboard focus off the entry
        if let Some(pt) = row.compute_point(&self.list, &gtk::graphene::Point::new(0.0, 0.0)) {
            let adj = self.scroll.vadjustment();
            let (y, h) = (f64::from(pt.y()), f64::from(row.height()));
            if y < adj.value() {
                adj.set_value(y);
            } else if y + h > adj.value() + adj.page_size() {
                adj.set_value(y + h - adj.page_size());
            }
        }
    }

    fn run_selected(self: &Rc<Self>) {
        let Some(row) = self.list.selected_row() else {
            return;
        };
        let Some(&idx) = self.shown.borrow().get(row.index() as usize) else {
            return;
        };
        let item = self.items.borrow()[idx].clone();
        if item.confirm && self.pending.get() != Some(idx) {
            self.pending.set(Some(idx));
            self.refresh_keep(idx);
            return;
        }
        self.close();
        // hyprctl is quick and this keeps the child from lingering as a zombie
        let _ = Command::new("hyprctl")
            .args(["dispatch", "exec", &item.exec])
            .status();
    }

    /// Re-render after arming a confirmation, keeping the same entry selected.
    fn refresh_keep(&self, idx: usize) {
        let pos = self.shown.borrow().iter().position(|&i| i == idx);
        let items = self.items.borrow();
        let shown = self.shown.borrow().clone();
        while let Some(row) = self.list.first_child() {
            self.list.remove(&row);
        }
        for &i in &shown {
            self.list
                .append(&self.row(&items[i], self.pending.get() == Some(i)));
        }
        if let Some(row) = pos.and_then(|p| self.list.row_at_index(p as i32)) {
            self.list.select_row(Some(&row));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn q(s: &str) -> Vec<char> {
        s.chars().collect()
    }

    #[test]
    fn fuzzy_needs_a_subsequence() {
        assert!(fuzzy(&q("ffx"), "Firefox").is_some());
        assert!(fuzzy(&q("xf"), "Firefox").is_none());
        assert!(fuzzy(&q("zzz"), "Firefox").is_none());
    }

    #[test]
    fn fuzzy_prefers_word_starts_and_runs() {
        let word = fuzzy(&q("tf"), "Toggle focus").unwrap();
        let scattered = fuzzy(&q("tf"), "Settings folder").unwrap();
        assert!(word > scattered);
        let run = fuzzy(&q("fire"), "Firefox").unwrap();
        let gaps = fuzzy(&q("fire"), "Fantasy Irregular Editor").unwrap();
        assert!(run > gaps);
    }

    #[test]
    fn quotes_survive_the_shell() {
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
    }

    #[test]
    fn web_search_url_is_encoded_and_quoted() {
        assert_eq!(url_encode("a b&c/ł"), "a%20b%26c%2F%C5%82");
        let it = web_item("rust gtk4", "https://example.org/?q=%s");
        assert_eq!(it.exec, "xdg-open 'https://example.org/?q=rust%20gtk4'");
        assert_eq!(it.group, "Web");
    }

    #[test]
    fn room_entries_map_to_items() {
        let entries = serde_json::json!([
            {"title": "x from Desktop", "group": "Inbox", "rank": 0, "exec": "room take x"},
            {"title": "Send proj to Desktop", "group": "Send", "rank": 2, "exec": "room send proj"},
            {"title": "no exec"},
        ]);
        let items = room_items(&entries);
        assert_eq!(items.len(), 2);
        assert_eq!((items[0].rank, items[1].rank), (0, 2));
        assert_eq!(items[0].exec, "room take x");
    }

    #[test]
    fn glyph_names_fall_back_to_action() {
        assert_eq!(glyph_named("lock"), Glyph::Lock);
        assert_eq!(glyph_named("nope"), Glyph::Action);
    }
}
