//! labd: owns the Kowal Lab state bus and draws the island.
//! `labd --no-ui` runs the bus alone and logs events, for tests and headless hosts.

use labd::bus;
mod glyphs;
mod island;
mod tokens;

use std::cell::RefCell;

use adw::prelude::*;
use gtk::{gdk, glib};
use gtk4 as gtk;
use libadwaita as adw;

const APP_ID: &str = "lab.justkowal.Labd";

fn main() -> glib::ExitCode {
    let (bus, rx) = bus::Bus::new();
    if let Err(e) = bus.serve(&bus::sock_path()) {
        eprintln!("labd: bus not started: {e}");
        return glib::ExitCode::FAILURE;
    }

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

        let island = island::Island::new(app, tokens);
        if let Some(rx) = rx.borrow_mut().take() {
            glib::spawn_future_local(async move {
                while let Ok(ev) = rx.recv().await {
                    island.on_event(&ev);
                }
            });
        }
        // the window only exists while an event is showing, so nothing else keeps the app alive
        std::mem::forget(app.hold());
    });
    app.connect_activate(|_| {});
    app.run()
}
