use std::cell::{Cell, RefCell};
use std::rc::Rc;

use accubattery::battery::{self, Battery};
use accubattery::control::{self, Mode};
use accubattery::db::Db;
use accubattery::engine::Status;
use adw::prelude::*;
use gtk4 as gtk;
use gtk4::{gio, glib};
use libadwaita as adw;

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

/// swap the dynamic rows of a group, skipping the work when nothing changed
fn refill(group: &adw::PreferencesGroup, store: &RefCell<Vec<adw::ActionRow>>, rows: Vec<adw::ActionRow>) {
    for r in store.borrow_mut().drain(..) {
        group.remove(&r);
    }
    for r in &rows {
        group.add(r);
    }
    group.set_visible(!rows.is_empty());
    *store.borrow_mut() = rows;
}

fn tone_of(c: &Cycle) -> &'static str {
    if c.session == "charge" { "success" } else { "warning" }
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
    apps_group: adw::PreferencesGroup,
    apps_rows: RefCell<Vec<adw::ActionRow>>,
    apps_key: RefCell<String>,
    // history
    hist_group: adw::PreferencesGroup,
    hist_rows: RefCell<Vec<adw::ActionRow>>,
    hist_key: Cell<(usize, i64)>,
    ev_group: adw::PreferencesGroup,
    ev_rows: RefCell<Vec<adw::ActionRow>>,
    // health
    h_pct: gtk::Label,
    h_graph: Graph,
    r_cap: adw::ActionRow,
    r_cycles: adw::ActionRow,
    r_deep: adw::ActionRow,
    r_offline: adw::ActionRow,
    r_wear30: adw::ActionRow,
    r_proj: adw::ActionRow,
    r_habit: adw::ActionRow,
    r_above: adw::ActionRow,
    sb_group: adw::PreferencesGroup,
    sb_rows: RefCell<Vec<adw::ActionRow>>,
    // settings
    s_alarm: adw::SwitchRow,
    s_target: adw::SpinRow,
    s_abm: adw::ComboRow,
    s_limit: adw::ComboRow,
    r_trip: adw::ActionRow,
    trip_btn: gtk::Button,
    trip_active: Cell<bool>,
    sc_on: adw::SwitchRow,
    sc_day: adw::ComboRow,
    sc_time: adw::EntryRow,
    sc_lead: adw::SpinRow,
    settings_ready: Cell<bool>,
    window: RefCell<Option<gtk::Window>>,
}

const ABM_LEVELS: [u8; 3] = [0, 2, 4];

fn on_worker(f: impl FnOnce(Battery, Option<Db>) + Send + 'static) {
    std::thread::spawn(move || {
        if let Some(b) = Battery::find() {
            f(b, Db::open().ok());
        }
    });
}

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
        for w in [pct.upcast_ref::<gtk::Widget>(), line.upcast_ref(), eta.upcast_ref(), graph.area.upcast_ref()] {
            top.append(w);
        }
        let g_top = adw::PreferencesGroup::new();
        g_top.add(&top);
        let (r_session, r_gain, r_wear, r_power, r_adapter, r_daemon) =
            (row("Session"), row("Change"), row("Wear"), row("Power policy"), row("Adapter"), row("Logger"));
        let g_sess = adw::PreferencesGroup::builder().title("Current session").build();
        for r in [&r_session, &r_gain, &r_wear, &r_power, &r_adapter, &r_daemon] {
            g_sess.add(r);
        }
        let apps_group = adw::PreferencesGroup::builder()
            .title("Top apps this session")
            .description("An estimate: CPU and GPU time share of the measured draw.")
            .visible(false)
            .build();
        let p_now = adw::PreferencesPage::new();
        p_now.add(&g_top);
        p_now.add(&g_sess);
        p_now.add(&apps_group);
        stack.add_titled_with_icon(&p_now, Some("now"), "Now", "battery-level-80-symbolic");

        // History
        let hist_group = adw::PreferencesGroup::builder()
            .title("Sessions")
            .description("Charges and drains found while the laptop was asleep or off are marked.")
            .build();
        let export_btn = gtk::Button::builder().label("Export").valign(gtk::Align::Center).build();
        hist_group.set_header_suffix(Some(&export_btn));
        let ev_group = adw::PreferencesGroup::builder()
            .title("Gauge notes")
            .description("Jumps in the battery gauge that no load explains. They are not logged as sessions.")
            .visible(false)
            .build();
        let p_hist = adw::PreferencesPage::new();
        p_hist.add(&hist_group);
        p_hist.add(&ev_group);
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
        let (r_cap, r_cycles, r_deep, r_offline, r_wear30, r_proj, r_habit, r_above) = (
            row("Capacity"),
            row("Charge cycles"),
            row("Charges above 90 %"),
            row("Found while asleep or off"),
            row("Wear in the last 30 days"),
            row("Projected 80 % health"),
            row("Charging habits"),
            row("Time above 90 % on AC"),
        );
        let g_stats = adw::PreferencesGroup::builder().title("Battery").build();
        for r in [&r_cap, &r_cycles, &r_proj, &r_wear30, &r_deep, &r_offline] {
            g_stats.add(r);
        }
        let g_habit = adw::PreferencesGroup::builder().title("Habits, last 30 days").build();
        g_habit.add(&r_habit);
        g_habit.add(&r_above);
        let sb_group = adw::PreferencesGroup::builder()
            .title("Standby drain")
            .description("Average draw while asleep, per night. Above 600 mW is worth a look.")
            .visible(false)
            .build();
        let p_health = adw::PreferencesPage::new();
        p_health.add(&g_h);
        p_health.add(&g_stats);
        p_health.add(&g_habit);
        p_health.add(&sb_group);
        stack.add_titled_with_icon(&p_health, Some("health"), "Health", "emblem-ok-symbolic");

        // Settings
        let s_alarm = adw::SwitchRow::builder().title("Charge alarm").subtitle("Show a card in the island once per charge").build();
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
        let trip_btn = gtk::Button::builder().label("Start").valign(gtk::Align::Center).build();
        let r_trip = adw::ActionRow::builder()
            .title("Full charge for a trip")
            .subtitle("Charges to 100 % for 12 hours, then restores the limit. Unplugging restores it sooner.")
            .build();
        r_trip.add_suffix(&trip_btn);
        let s_abm = adw::ComboRow::builder()
            .title("Display power saving")
            .subtitle("AMD adaptive backlight. Higher saves power and lowers contrast.")
            .model(&gtk::StringList::new(&["Off", "Balanced", "Maximum"]))
            .build();
        let g_hw = adw::PreferencesGroup::builder().title("Hardware").build();
        g_hw.add(&s_limit);
        g_hw.add(&r_trip);
        g_hw.add(&s_abm);

        let sc_on = adw::SwitchRow::builder().title("Full charge before a fixed time").subtitle("Every week on the chosen day").build();
        let sc_day = adw::ComboRow::builder().title("Day").model(&gtk::StringList::new(&control::DAYS)).build();
        let sc_time = adw::EntryRow::builder().title("Ready by (HH:MM)").text("06:30").build();
        let sc_lead = adw::SpinRow::with_range(1.0, 8.0, 1.0);
        sc_lead.set_title("Start charging this many hours before");
        let g_sched = adw::PreferencesGroup::builder()
            .title("Schedule")
            .description("Works with the calendar check: that one covers travel days, this one covers a fixed weekly time.")
            .build();
        for w in [sc_on.upcast_ref::<gtk::Widget>(), sc_day.upcast_ref(), sc_time.upcast_ref(), sc_lead.upcast_ref()] {
            g_sched.add(w);
        }

        let p_set = adw::PreferencesPage::new();
        p_set.add(&g_alarm);
        p_set.add(&g_hw);
        p_set.add(&g_sched);
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
            apps_group,
            apps_rows: RefCell::default(),
            apps_key: RefCell::default(),
            hist_group,
            hist_rows: RefCell::default(),
            hist_key: Cell::new((usize::MAX, 0)),
            ev_group,
            ev_rows: RefCell::default(),
            h_pct,
            h_graph,
            r_cap,
            r_cycles,
            r_deep,
            r_offline,
            r_wear30,
            r_proj,
            r_habit,
            r_above,
            sb_group,
            sb_rows: RefCell::default(),
            s_alarm,
            s_target,
            s_abm,
            s_limit,
            r_trip,
            trip_btn,
            trip_active: Cell::new(false),
            sc_on,
            sc_day,
            sc_time,
            sc_lead,
            settings_ready: Cell::new(false),
            window: RefCell::new(None),
        });
        ui.wire(&export_btn);
        ui
    }

    pub fn set_window(&self, w: &impl IsA<gtk::Window>) {
        *self.window.borrow_mut() = Some(w.clone().upcast());
    }

    fn wire(self: &Rc<Self>, export_btn: &gtk::Button) {
        let ready = |ui: &Rc<Self>| ui.settings_ready.get();
        let ui = self.clone();
        self.s_alarm.connect_active_notify(move |r| {
            if ready(&ui) {
                data::set_setting("alarm_enabled", if r.is_active() { "true" } else { "false" });
            }
        });
        let ui = self.clone();
        self.s_target.connect_value_notify(move |r| {
            if ready(&ui) {
                data::set_setting("alarm_target", &format!("{}", r.value() as i64));
            }
        });
        let ui = self.clone();
        self.s_abm.connect_selected_notify(move |r| {
            if ready(&ui) {
                let level = ABM_LEVELS[(r.selected() as usize).min(2)];
                std::thread::spawn(move || {
                    let _ = battery::set_abm(level);
                });
            }
        });
        let ui = self.clone();
        self.s_limit.connect_selected_notify(move |r| {
            if !ready(&ui) {
                return;
            }
            let full = r.selected() == 0;
            on_worker(move |b, db| {
                let _ = if full { control::set_mode(&b, Mode::Travel, db.as_ref()) } else { control::end_trip(&b, db.as_ref()) };
            });
        });
        let ui = self.clone();
        self.trip_btn.connect_clicked(move |_| {
            let cancel = ui.trip_active.get();
            on_worker(move |b, db| {
                let _ = if cancel {
                    control::end_trip(&b, db.as_ref())
                } else {
                    control::start_trip(&b, 12.0, false, battery::now(), db.as_ref()).map(|_| ())
                };
            });
        });

        let ui = self.clone();
        self.sc_on.connect_active_notify(move |r| {
            if ready(&ui) {
                data::set_setting("sched_enabled", if r.is_active() { "true" } else { "false" });
            }
        });
        let ui = self.clone();
        self.sc_day.connect_selected_notify(move |r| {
            if ready(&ui) {
                data::set_setting("sched_dow", &r.selected().to_string());
            }
        });
        let ui = self.clone();
        self.sc_time.connect_changed(move |r| {
            if let (true, Some(m)) = (ready(&ui), control::parse_hhmm(&r.text())) {
                r.remove_css_class("error");
                data::set_setting("sched_time", &format!("{:02}:{:02}", m / 60, m % 60));
            } else if ready(&ui) {
                r.add_css_class("error");
            }
        });
        let ui = self.clone();
        self.sc_lead.connect_value_notify(move |r| {
            if ready(&ui) {
                data::set_setting("sched_lead_h", &format!("{}", r.value() as i64));
            }
        });

        let ui = self.clone();
        export_btn.connect_clicked(move |_| ui.export());
    }

    fn export(&self) {
        let dialog = gtk::FileDialog::builder().title("Export history").initial_name("accubattery.csv").build();
        let win = self.window.borrow().clone();
        dialog.save(win.as_ref(), gio::Cancellable::NONE, |res| {
            let Some(path) = res.ok().and_then(|f| f.path()) else { return };
            std::thread::spawn(move || {
                let Ok(db) = Db::open() else { return };
                let json = path.extension().is_some_and(|e| e == "json");
                let body = if json { accubattery::export::json(&db) } else { accubattery::export::csv(&db) };
                if let Ok(b) = body {
                    let _ = std::fs::write(path, b);
                }
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
                let i = ABM_LEVELS.iter().position(|v| i64::from(*v) == l).unwrap_or(if l >= 3 { 2 } else { 1 });
                self.s_abm.set_selected(i as u32);
            }
            if let Some(t) = s.stop_threshold {
                self.s_limit.set_selected(if t >= 95 { 0 } else { 1 });
                self.s_limit.set_subtitle(&format!("Hardware stops charging at {t} %"));
            }
            self.sc_on.set_active(s.sched_enabled);
            self.sc_day.set_selected(s.sched_dow.min(6));
            self.sc_time.set_text(&s.sched_time);
            self.sc_lead.set_value(f64::from(s.sched_lead_h));
            self.settings_ready.set(true);
        }
        self.trip_active.set(s.trip_until.is_some());
        match s.trip_until {
            Some(t) => {
                self.trip_btn.set_label("Cancel");
                self.r_trip.set_subtitle(&format!("Active until {} or when unplugged", fmt_date(t)));
            }
            None => {
                self.trip_btn.set_label("Start");
                self.r_trip.set_subtitle("Charges to 100 % for 12 hours, then restores the limit. Unplugging restores it sooner.");
            }
        }
    }

    fn update_now(&self, s: &Snapshot) {
        let Some(l) = &s.live else {
            self.pct.set_text("No battery");
            return;
        };
        let name = if s.battery_count > 1 { format!(" ({})", s.battery_name) } else { String::new() };
        self.pct.set_text(&format!("{:.0} %{name}", l.pct));
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
            ..Default::default()
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

        let key = s.active_apps.iter().map(|a| format!("{}{:.3}", a.0, a.1)).collect::<String>();
        if *self.apps_key.borrow() != key {
            *self.apps_key.borrow_mut() = key;
            let rows = s
                .active_apps
                .iter()
                .take(5)
                .map(|(n, wh, share)| {
                    let r = adw::ActionRow::builder().title(glib::markup_escape_text(n)).subtitle(format!("{wh:.2} Wh, {share:.0} %")).build();
                    r
                })
                .collect();
            refill(&self.apps_group, &self.apps_rows, rows);
        }
    }

    fn update_history(self: &Rc<Self>, s: &Snapshot) {
        let ev: Vec<adw::ActionRow> = s
            .events
            .iter()
            .map(|(t, d)| adw::ActionRow::builder().title(glib::markup_escape_text(d)).subtitle(fmt_date(*t)).build())
            .collect();
        refill(&self.ev_group, &self.ev_rows, ev);

        let key = (s.cycles.len(), s.cycles.first().map(|c| c.id).unwrap_or(0));
        if key == self.hist_key.get() {
            return;
        }
        self.hist_key.set(key);
        for r in self.hist_rows.borrow_mut().drain(..) {
            self.hist_group.remove(&r);
        }
        for c in &s.cycles {
            let battery = if s.battery_count > 1 { format!(" ({})", c.battery) } else { String::new() };
            let extra = if c.kind == "sleep_drain" && c.duration_min > 0.0 {
                format!(", {:.0} mW", c.wh / (c.duration_min / 60.0) * 1000.0)
            } else {
                String::new()
            };
            let r = adw::ActionRow::builder()
                .title(format!("{}{battery}, {:.0} % to {:.0} %", kind_label(c), c.start_pct, c.end_pct))
                .subtitle(format!("{}, {}, {:.1} Wh{extra}", fmt_date(c.start), fmt_dur(c.duration_min), c.wh))
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
        let win = adw::Window::builder().title(kind_label(c)).default_width(560).default_height(680).modal(true).build();
        if let Some(p) = self.window.borrow().as_ref() {
            win.set_transient_for(Some(p));
        }
        let graph = Graph::new(200);
        let g = adw::PreferencesGroup::new();
        g.add(&graph.area);
        let stats = adw::PreferencesGroup::builder().title("Details").build();
        let add = |t: &str, v: String| {
            let r = row(t);
            r.set_subtitle(&glib::markup_escape_text(&v));
            stats.add(&r);
        };
        add("Started", fmt_date(c.start));
        add("Duration", fmt_dur(c.duration_min));
        add("Change", format!("{:.0} % to {:.0} %", c.start_pct, c.end_pct));
        add("Energy", format!("{:.1} Wh ({:.0} mAh)", c.wh, c.mah));
        add("Power", format!("{:.1} W average, {:.1} W peak", c.avg_w, c.max_w));
        if c.max_t > 0.0 {
            add("Temperature", format!("{:.0} C average, {:.0} C peak", c.avg_t, c.max_t));
        }
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
        if !c.wake.is_empty() {
            let w = adw::PreferencesGroup::builder().title("Woken by").build();
            for (name, count, ms) in &c.wake {
                let r = row(name);
                r.set_subtitle(&format!("{count} wakeups, {:.1} s active", *ms as f64 / 1000.0));
                w.add(&r);
            }
            page.add(&w);
        }
        if !c.apps.is_empty() {
            let a = adw::PreferencesGroup::builder().title("Top apps (estimate)").build();
            for (name, wh, share) in c.apps.iter().take(8) {
                let r = row(name);
                r.set_subtitle(&format!("{wh:.2} Wh, {share:.0} %"));
                a.add(&r);
            }
            page.add(&a);
        }
        let tb = adw::ToolbarView::new();
        tb.add_top_bar(&adw::HeaderBar::new());
        tb.set_content(Some(&page));
        win.set_content(Some(&tb));
        win.present();

        let tone = tone_of(c);
        let id = c.id;
        let (tx, rx) = async_channel::bounded(1);
        std::thread::spawn(move || {
            let pts = Db::open().map(|d| data::points(&d, id)).unwrap_or_default();
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
                    ..Default::default()
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

        let projection = match (&s.projection, s.health.last()) {
            (Some((_, t_end)), Some(last)) => vec![*last, (*t_end, 80.0)],
            _ => Vec::new(),
        };
        self.h_graph.set(Series { primary: s.health.clone(), projection, range: None, unit: "%", tone: "accent", ..Default::default() });
        self.r_proj.set_subtitle(&match s.projection {
            Some((slope, t)) => format!(
                "{} at {:.2} % per month (a straight-line guess)",
                glib::DateTime::from_unix_local(t as i64).ok().and_then(|d| d.format("%b %Y").ok()).map(|x| x.to_string()).unwrap_or_default(),
                -slope * 30.0
            ),
            None => "Needs 30 days of data and a falling trend".into(),
        });

        let now = l.wall;
        let charges: Vec<&Cycle> = s.cycles.iter().filter(|c| c.session == "charge").collect();
        let w30: f64 = charges.iter().filter(|c| now - c.start < 30.0 * 86400.0).map(|c| c.wear).sum();
        self.r_wear30.set_subtitle(&format!("{w30:.2} cycles"));
        let deep = charges.iter().filter(|c| c.end_pct > 90.0).count();
        self.r_deep.set_subtitle(&format!("{deep} of {} charges", charges.len()));
        self.r_offline.set_subtitle(&s.cycles.iter().filter(|c| c.kind != "live").count().to_string());

        match s.habit {
            Some((score, tip)) => {
                self.r_habit.set_title(&format!("Charging habits: {score} / 100"));
                self.r_habit.set_subtitle(tip);
            }
            None => {
                self.r_habit.set_title("Charging habits");
                self.r_habit.set_subtitle("Needs at least 3 charges in the last 30 days");
            }
        }
        self.r_above.set_subtitle(&format!("{:.0} h", s.above_90_h));

        let rows = s
            .standby
            .iter()
            .map(|(day, mw, culprit)| {
                let r = adw::ActionRow::builder()
                    .title(day.as_str())
                    .subtitle(match culprit {
                        Some(c) => format!("{mw:.0} mW, woken most by {}", glib::markup_escape_text(c)),
                        None => format!("{mw:.0} mW"),
                    })
                    .build();
                if *mw > 600.0 {
                    let w = dim("high");
                    w.add_css_class("warning");
                    w.set_valign(gtk::Align::Center);
                    r.add_suffix(&w);
                }
                r
            })
            .collect();
        refill(&self.sb_group, &self.sb_rows, rows);
    }
}

/// Estimate comes from the daemon, which knows the learned charge profile and hour-of-week habits.
fn eta_text(s: &Snapshot) -> String {
    let Some(e) = s.state.as_ref().map(|v| &v["eta"]).filter(|e| e["minutes"].is_number()) else { return String::new() };
    let m = e["minutes"].as_f64().unwrap_or(0.0);
    match e["kind"].as_str() {
        Some("empty") => format!("About {} left, an estimate from your usual day", fmt_dur(m)),
        Some("target") if m < 1.0 => "Target reached".into(),
        Some("target") => format!("About {} to {:.0} %", fmt_dur(m), e["target"].as_f64().unwrap_or(100.0)),
        _ => String::new(),
    }
}

fn temp_suffix(t: f64) -> String {
    if t > 0.0 { format!(", {t:.0} C") } else { String::new() }
}
