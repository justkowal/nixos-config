use std::cell::{Cell, RefCell};
use std::rc::Rc;

use accubattery::engine::Status;
use gtk4 as gtk;
use gtk4::glib;
use libadwaita as adw;
use adw::prelude::*;

use crate::data::{self, Cycle, Snapshot};
use crate::graph::{Graph, Series};

pub fn fmt_dur(min: f64) -> String {
    let m = min.round() as i64;
    match (m / 60, m % 60) {
        (0, m) => format!("{m} min"),
        (h, 0) => format!("{h} h"),
        (h, m) => format!("{h} h {m} min"),
    }
}

pub fn fmt_date(t: f64) -> String {
    glib::DateTime::from_unix_local(t as i64)
        .ok()
        .and_then(|d| d.format("%d %b %H:%M").ok())
        .map(|s| s.to_string())
        .unwrap_or_default()
}

pub fn kind_label(c: &Cycle) -> &'static str {
    match (c.kind.as_str(), c.session.as_str()) {
        ("off_charge", _) => "Charged while off",
        ("off_drain", _) => "Drained while off",
        ("sleep_charge", _) => "Charged asleep",
        ("sleep_drain", _) => "Standby drain",
        (_, "charge") => "Charge",
        _ => "Discharge",
    }
}

fn row(title: &str) -> adw::ActionRow {
    let r = adw::ActionRow::builder().title(title).subtitle("-").build();
    r.add_css_class("property");
    r
}

fn big_label() -> gtk::Label {
    let l = gtk::Label::builder().halign(gtk::Align::Start).build();
    l.add_css_class("title-1");
    l
}

fn dim(text: &str) -> gtk::Label {
    let l = gtk::Label::builder().label(text).halign(gtk::Align::Start).wrap(true).build();
    l.add_css_class("dim-label");
    l
}

pub struct Ui {
    pub stack: adw::ViewStack,
    // now
    pct: gtk::Label,
    line: gtk::Label,
    eta: gtk::Label,
    graph: Graph,
    r_session: adw::ActionRow,
    r_gain: adw::ActionRow,
    r_wear: adw::ActionRow,
    r_power: adw::ActionRow,
    r_adapter: adw::ActionRow,
    r_daemon: adw::ActionRow,
    // history
    hist_group: adw::PreferencesGroup,
    hist_rows: RefCell<Vec<adw::ActionRow>>,
    hist_key: Cell<(usize, i64)>,
    // health
    h_pct: gtk::Label,
    h_graph: Graph,
    r_cap: adw::ActionRow,
    r_cycles: adw::ActionRow,
    r_deep: adw::ActionRow,
    r_offline: adw::ActionRow,
    r_wear30: adw::ActionRow,
    // settings
    s_alarm: adw::SwitchRow,
    s_target: adw::SpinRow,
    s_abm: adw::ComboRow,
    s_limit: adw::ComboRow,
    settings_ready: Cell<bool>,
    window: RefCell<Option<gtk::Window>>,
}

const ABM_LEVELS: [i64; 3] = [0, 2, 4];

impl Ui {
    pub fn new() -> Rc<Self> {
        let stack = adw::ViewStack::new();

        // Now
        let pct = big_label();
        pct.add_css_class("numeric");
        let line = dim("");
        let eta = gtk::Label::builder().halign(gtk::Align::Start).build();
        let graph = Graph::new(190);
        let top = gtk::Box::new(gtk::Orientation::Vertical, 6);
        top.append(&pct);
        top.append(&line);
        top.append(&eta);
        top.append(&graph.area);
        let g_top = adw::PreferencesGroup::new();
        g_top.add(&top);
        let r_session = row("Session");
        let r_gain = row("Change");
        let r_wear = row("Wear");
        let r_power = row("Power policy");
        let r_adapter = row("Adapter");
        let r_daemon = row("Logger");
        let g_sess = adw::PreferencesGroup::builder().title("Current session").build();
        for r in [&r_session, &r_gain, &r_wear, &r_power, &r_adapter, &r_daemon] {
            g_sess.add(r);
        }
        let p_now = adw::PreferencesPage::new();
        p_now.add(&g_top);
        p_now.add(&g_sess);
        stack.add_titled_with_icon(&p_now, Some("now"), "Now", "battery-level-80-symbolic");

        // History
        let hist_group = adw::PreferencesGroup::builder()
            .title("Sessions")
            .description("Charges and drains found while the laptop was asleep or off are marked.")
            .build();
        let p_hist = adw::PreferencesPage::new();
        p_hist.add(&hist_group);
        stack.add_titled_with_icon(&p_hist, Some("history"), "History", "document-open-recent-symbolic");

        // Health
        let h_pct = big_label();
        let h_graph = Graph::new(170);
        let hb = gtk::Box::new(gtk::Orientation::Vertical, 6);
        hb.append(&h_pct);
        hb.append(&dim("Full charge capacity against design capacity"));
        hb.append(&h_graph.area);
        let g_h = adw::PreferencesGroup::new();
        g_h.add(&hb);
        let r_cap = row("Capacity");
        let r_cycles = row("Charge cycles");
        let r_deep = row("Charges above 90 %");
        let r_offline = row("Found while asleep or off");
        let r_wear30 = row("Wear in the last 30 days");
        let g_stats = adw::PreferencesGroup::builder().title("Battery").build();
        for r in [&r_cap, &r_cycles, &r_wear30, &r_deep, &r_offline] {
            g_stats.add(r);
        }
        let p_health = adw::PreferencesPage::new();
        p_health.add(&g_h);
        p_health.add(&g_stats);
        stack.add_titled_with_icon(&p_health, Some("health"), "Health", "emblem-ok-symbolic");

        // Settings
        let s_alarm = adw::SwitchRow::builder().title("Charge alarm").subtitle("Notify once per charge when the target is reached").build();
        let s_target = adw::SpinRow::with_range(50.0, 100.0, 1.0);
        s_target.set_title("Alarm target");
        s_target.set_subtitle("Percent");
        let g_alarm = adw::PreferencesGroup::builder().title("Alarm").build();
        g_alarm.add(&s_alarm);
        g_alarm.add(&s_target);
        let s_limit = adw::ComboRow::builder()
            .title("Charge limit")
            .model(&gtk::StringList::new(&["Full capacity", "Conservation"]))
            .build();
        let s_abm = adw::ComboRow::builder()
            .title("Display power saving")
            .subtitle("AMD adaptive backlight. Higher saves power and lowers contrast.")
            .model(&gtk::StringList::new(&["Off", "Balanced", "Maximum"]))
            .build();
        let g_hw = adw::PreferencesGroup::builder().title("Hardware").build();
        g_hw.add(&s_limit);
        g_hw.add(&s_abm);
        let p_set = adw::PreferencesPage::new();
        p_set.add(&g_alarm);
        p_set.add(&g_hw);
        stack.add_titled_with_icon(&p_set, Some("settings"), "Settings", "preferences-system-symbolic");

        let ui = Rc::new(Self {
            stack,
            pct,
            line,
            eta,
            graph,
            r_session,
            r_gain,
            r_wear,
            r_power,
            r_adapter,
            r_daemon,
            hist_group,
            hist_rows: RefCell::default(),
            hist_key: Cell::new((usize::MAX, 0)),
            h_pct,
            h_graph,
            r_cap,
            r_cycles,
            r_deep,
            r_offline,
            r_wear30,
            s_alarm,
            s_target,
            s_abm,
            s_limit,
            settings_ready: Cell::new(false),
            window: RefCell::new(None),
        });
        ui.wire_settings();
        ui
    }

    pub fn set_window(&self, w: &impl IsA<gtk::Window>) {
        *self.window.borrow_mut() = Some(w.clone().upcast());
    }

    fn wire_settings(self: &Rc<Self>) {
        let ui = self.clone();
        self.s_alarm.connect_active_notify(move |r| {
            if ui.settings_ready.get() {
                data::set_setting("alarm_enabled", if r.is_active() { "true" } else { "false" });
            }
        });
        let ui = self.clone();
        self.s_target.connect_value_notify(move |r| {
            if ui.settings_ready.get() {
                data::set_setting("alarm_target", &format!("{}", r.value() as i64));
            }
        });
        let ui = self.clone();
        self.s_abm.connect_selected_notify(move |r| {
            if !ui.settings_ready.get() {
                return;
            }
            let level = ABM_LEVELS[(r.selected() as usize).min(2)];
            std::thread::spawn(move || {
                for f in data::abm_files() {
                    if std::fs::write(&f, level.to_string()).is_err() {
                        let _ = std::process::Command::new("pkexec")
                            .args(["sh", "-c", &format!("echo {level} > {}", f.display())])
                            .output();
                    }
                }
            });
        });
        let ui = self.clone();
        self.s_limit.connect_selected_notify(move |r| {
            if !ui.settings_ready.get() {
                return;
            }
            let opt = if r.selected() == 0 { "--trip" } else { "--conserve" };
            std::thread::spawn(move || {
                let _ = std::process::Command::new("batmon").arg(opt).output();
            });
        });
    }

    pub fn update(self: &Rc<Self>, s: &Snapshot) {
        self.update_now(s);
        self.update_history(s);
        self.update_health(s);
        if !self.settings_ready.get() {
            self.s_alarm.set_active(s.alarm_enabled);
            self.s_target.set_value(s.alarm_target);
            if let Some(l) = s.abm {
                let i = ABM_LEVELS.iter().position(|v| *v == l).unwrap_or(if l >= 3 { 2 } else { 1 });
                self.s_abm.set_selected(i as u32);
            }
            if let Some(t) = s.stop_threshold {
                self.s_limit.set_selected(if t >= 95 { 0 } else { 1 });
                self.s_limit.set_subtitle(&format!("Hardware stops charging at {t} %"));
            }
            self.settings_ready.set(true);
        }
    }

    fn update_now(&self, s: &Snapshot) {
        let Some(l) = &s.live else {
            self.pct.set_text("No battery");
            return;
        };
        self.pct.set_text(&format!("{:.0} %", l.pct));
        let state = match l.status {
            Status::Charging => format!("Charging at {:.1} W, {:.0} mA{}", l.watts, l.ma, temp_suffix(l.temp)),
            Status::Discharging => format!("Using {:.1} W, {:.0} mA{}", l.watts, l.ma, temp_suffix(l.temp)),
            Status::Idle if l.ac => format!("Plugged in, not charging{}", temp_suffix(l.temp)),
            Status::Idle => "Idle".into(),
        };
        self.line.set_text(&state);
        self.eta.set_text(&eta_text(s));

        let tone = if l.status == Status::Charging { "success" } else { "warning" };
        self.graph.set(Series {
            primary: s.active.iter().map(|p| (p.t, p.pct)).collect(),
            secondary: s.active.iter().map(|p| (p.t, p.watts)).collect(),
            range: Some((0.0, 100.0)),
            unit: "%",
            tone,
        });

        let st = s.state.as_ref();
        let start_pct = st.and_then(|v| v["start_pct"].as_f64());
        let start_t = st.and_then(|v| v["start_time"].as_f64());
        match (start_pct, start_t, st.and_then(|v| v["kind"].as_str())) {
            (Some(sp), Some(t0), Some(kind)) => {
                let dur = (l.wall - t0) / 60.0;
                self.r_session.set_subtitle(&format!(
                    "{} since {} ({})",
                    if kind == "charge" { "Charging" } else { "Discharging" },
                    fmt_date(t0),
                    fmt_dur(dur)
                ));
                let dp = l.pct - sp;
                let wh = dp.abs() / 100.0 * l.full_wh;
                self.r_gain.set_subtitle(&format!("{sp:.0} % to {:.0} %, {:+.1} %, {wh:.1} Wh", l.pct, dp));
                self.r_wear.set_subtitle(&if kind == "charge" {
                    let w = accubattery::engine::wear(sp, l.pct);
                    format!("{w:.2} cycles{}", if l.pct > 80.0 { ", above 80 % stresses the cell" } else { "" })
                } else {
                    "Only charging wears the battery in this model".into()
                });
            }
            _ => {
                self.r_session.set_subtitle("No active session");
                self.r_gain.set_subtitle("-");
                self.r_wear.set_subtitle("-");
            }
        }
        let p = st.and_then(|v| v["power"]["mode"].as_str()).unwrap_or("standard");
        self.r_power.set_subtitle(match p {
            "charging_awake" => "Kept awake while charging so the session is logged",
            "countdown" => "Charged and idle, the laptop will sleep soon",
            "caffeine_manual" => "Caffeine is on, no automatic sleep",
            "charged_active" => "Charged, normal policies while in use",
            _ => "Normal suspend and idle timeouts",
        });
        self.r_adapter.set_subtitle(st.and_then(|v| v["pd"].as_str()).unwrap_or(if l.ac { "AC" } else { "On battery" }));
        self.r_daemon.set_subtitle(if s.daemon_up { "Running" } else { "Not running, nothing is being recorded" });
    }

    fn update_history(self: &Rc<Self>, s: &Snapshot) {
        let key = (s.cycles.len(), s.cycles.first().map(|c| c.id).unwrap_or(0));
        if key == self.hist_key.get() {
            return;
        }
        self.hist_key.set(key);
        for r in self.hist_rows.borrow_mut().drain(..) {
            self.hist_group.remove(&r);
        }
        for c in &s.cycles {
            let r = adw::ActionRow::builder()
                .title(format!("{}, {:.0} % to {:.0} %", kind_label(c), c.start_pct, c.end_pct))
                .subtitle(format!("{}, {}, {:.1} Wh", fmt_date(c.start), fmt_dur(c.duration_min), c.wh))
                .activatable(true)
                .build();
            if c.session == "charge" {
                let w = dim(&format!("{:.2} cyc", c.wear));
                w.set_valign(gtk::Align::Center);
                r.add_suffix(&w);
            }
            r.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
            let ui = self.clone();
            let c = c.clone();
            r.connect_activated(move |_| ui.open_detail(&c));
            self.hist_group.add(&r);
            self.hist_rows.borrow_mut().push(r);
        }
    }

    fn open_detail(&self, c: &Cycle) {
        let win = adw::Window::builder().title(kind_label(c)).default_width(560).default_height(620).modal(true).build();
        if let Some(p) = self.window.borrow().as_ref() {
            win.set_transient_for(Some(p));
        }
        let graph = Graph::new(200);
        let g = adw::PreferencesGroup::new();
        g.add(&graph.area);
        let stats = adw::PreferencesGroup::builder().title("Details").build();
        let add = |t: &str, v: String| {
            let r = row(t);
            r.set_subtitle(&v);
            stats.add(&r);
        };
        add("Started", fmt_date(c.start));
        add("Duration", fmt_dur(c.duration_min));
        add("Change", format!("{:.0} % to {:.0} %", c.start_pct, c.end_pct));
        add("Energy", format!("{:.1} Wh ({:.0} mAh)", c.wh, c.mah));
        add("Power", format!("{:.1} W average, {:.1} W peak", c.avg_w, c.max_w));
        add("Temperature", format!("{:.0} C average, {:.0} C peak", c.avg_t, c.max_t));
        if c.session == "charge" {
            add("Wear", format!("{:.2} cycles", c.wear));
        }
        if let Some(pd) = &c.pd {
            add("Adapter", pd.clone());
        }
        if c.kind != "live" {
            add("Source", "Reconstructed from the battery gauge, no live samples exist for this interval".into());
        }
        let page = adw::PreferencesPage::new();
        page.add(&g);
        page.add(&stats);
        let tb = adw::ToolbarView::new();
        tb.add_top_bar(&adw::HeaderBar::new());
        tb.set_content(Some(&page));
        win.set_content(Some(&tb));
        win.present();

        let tone = if c.session == "charge" { "success" } else { "warning" };
        let id = c.id;
        let (tx, rx) = async_channel::bounded(1);
        std::thread::spawn(move || {
            let pts = accubattery::db::Db::open().map(|d| data::points(&d, id)).unwrap_or_default();
            let _ = tx.send_blocking(pts);
        });
        glib::spawn_future_local(async move {
            if let Ok(pts) = rx.recv().await {
                graph.set(Series {
                    primary: pts.iter().map(|p| (p.t, p.pct)).collect(),
                    secondary: pts.iter().map(|p| (p.t, p.watts)).collect(),
                    range: Some((0.0, 100.0)),
                    unit: "%",
                    tone,
                });
            }
        });
    }

    fn update_health(&self, s: &Snapshot) {
        let Some(l) = &s.live else { return };
        let health = if s.design_wh > 0.0 { l.full_wh / s.design_wh * 100.0 } else { 0.0 };
        self.h_pct.set_text(&format!("{health:.1} %"));
        self.r_cap.set_subtitle(&format!("{:.1} Wh of {:.1} Wh design", l.full_wh, s.design_wh));
        self.r_cycles.set_subtitle(&s.cycle_count.to_string());
        self.h_graph.set(Series {
            primary: s.health.clone(),
            secondary: Vec::new(),
            range: None,
            unit: "%",
            tone: "accent",
        });
        let now = l.wall;
        let charges: Vec<&Cycle> = s.cycles.iter().filter(|c| c.session == "charge").collect();
        let w30: f64 = charges.iter().filter(|c| now - c.start < 30.0 * 86400.0).map(|c| c.wear).sum();
        self.r_wear30.set_subtitle(&format!("{w30:.2} cycles"));
        let deep = charges.iter().filter(|c| c.end_pct > 90.0).count();
        self.r_deep.set_subtitle(&format!("{deep} of {} charges", charges.len()));
        let off = s.cycles.iter().filter(|c| c.kind != "live").count();
        self.r_offline.set_subtitle(&off.to_string());
    }
}

fn eta_text(s: &Snapshot) -> String {
    let Some(l) = &s.live else { return String::new() };
    let recent: Vec<f64> = s.active.iter().rev().take(12).map(|p| p.watts).filter(|w| *w > 0.5).collect();
    let w = if recent.is_empty() { l.watts } else { recent.iter().sum::<f64>() / recent.len() as f64 };
    if w < 0.5 {
        return String::new();
    }
    match l.status {
        Status::Discharging => {
            let h = l.wh / w;
            format!("About {} left at this draw", fmt_dur(h * 60.0))
        }
        Status::Charging => {
            let target = s.alarm_target.max(l.pct);
            let full_wh = l.full_wh;
            // above 80 % the current tapers, count that stretch at half speed
            let fast = (target.min(80.0) - l.pct).max(0.0) / 100.0 * full_wh;
            let slow = (target - target.min(80.0).max(l.pct)).max(0.0) / 100.0 * full_wh;
            let h = fast / w + slow / (w * 0.5);
            if h <= 0.0 {
                "Target reached".into()
            } else {
                format!("About {} to {:.0} %", fmt_dur(h * 60.0), target)
            }
        }
        Status::Idle => String::new(),
    }
}

fn temp_suffix(t: f64) -> String {
    if t > 0.0 { format!(", {t:.0} C") } else { String::new() }
}
