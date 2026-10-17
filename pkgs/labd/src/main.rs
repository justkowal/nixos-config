//! labd: owns the Kowal Lab state bus, draws the island and the command palette.
//! `labd --no-ui` runs the bus alone and logs events, for tests and headless hosts.

mod bar;
mod engine;
mod glyphs;
mod help;
mod island;
mod motion;
mod palette;
mod tokens;
mod tray;

use std::cell::RefCell;

use adw::prelude::*;
use gtk::{gdk, glib};
use gtk4 as gtk;
use labd::bus;
use libadwaita as adw;

const APP_ID: &str = "lab.justkowal.Labd";

fn main() -> glib::ExitCode {
    let (bus, rx) = bus::Bus::new();
    if let Err(e) = bus.serve(&bus::sock_path()) {
        eprintln!("labd: bus not started: {e}");
        return glib::ExitCode::FAILURE;
    }

    // off unless phone.json enables it, and then only on the tailnet address
    labd::phone::start_from_config(std::sync::Arc::clone(&bus));

    if std::env::args().any(|a| a == "--no-ui") {
        while let Ok(ev) = rx.recv_blocking() {
            eprintln!("{ev}");
        }
        return glib::ExitCode::SUCCESS;
    }

    let app = adw::Application::builder().application_id(APP_ID).build();
    let rx = RefCell::new(Some(rx));
    app.connect_startup(move |app| {
        let tokens = tokens::Tokens::load();
        let css = gtk::CssProvider::new();
        css.load_from_string(&tokens.css());
        if let Some(display) = gdk::Display::default() {
            gtk::style_context_add_provider_for_display(
                &display,
                &css,
                gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
            );
        }
        adw::StyleManager::default().set_color_scheme(adw::ColorScheme::PreferDark);

        let island = island::Island::new(app, &tokens, motion::Motion::new(&tokens));
        let help = help::Help::new(app);
        let bar = bar::Bar::new(app);
        let engine = engine::Engine::new(&tokens);
        let palette = palette::Palette::new(app, &tokens, motion::Motion::new(&tokens));
        if let Some(rx) = rx.borrow_mut().take() {
            glib::spawn_future_local(async move {
                while let Ok(ev) = rx.recv().await {
                    engine.handle(&ev);
                    if let Some(bar) = &bar {
                        bar.on_event(&ev);
                    }
                    match ev["name"].as_str() {
                        Some("palette.toggle") => palette.toggle(),
                        Some("help.toggle") => help.toggle(ev["payload"]["page"].as_str()),
                        _ => island.on_event(&ev),
                    }
                }
            });
        }
        // windows only exist while showing, so nothing else keeps the app alive
        std::mem::forget(app.hold());
    });
    app.connect_activate(|_| {});
    app.run()
}
