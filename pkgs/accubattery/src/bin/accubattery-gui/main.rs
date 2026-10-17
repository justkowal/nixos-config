mod data;
mod graph;
mod ui;

use std::rc::Rc;
use std::time::Duration;

use accubattery::battery::Battery;
use adw::prelude::*;
use gtk4 as gtk;
use gtk4::glib;
use libadwaita as adw;

const APP_ID: &str = "lab.justkowal.AccuBattery";

fn main() -> glib::ExitCode {
    let app = adw::Application::builder().application_id(APP_ID).build();
    app.connect_activate(|app| {
        if let Some(w) = app.active_window() {
            w.present();
            return;
        }
        let ui = ui::Ui::new();
        let switcher = adw::ViewSwitcher::builder().stack(&ui.stack).policy(adw::ViewSwitcherPolicy::Wide).build();
        let header = adw::HeaderBar::builder().title_widget(&switcher).build();
        let bar = adw::ViewSwitcherBar::builder().stack(&ui.stack).build();
        let tb = adw::ToolbarView::new();
        tb.add_top_bar(&header);
        tb.add_bottom_bar(&bar);
        tb.set_content(Some(&ui.stack));
        let win = adw::ApplicationWindow::builder()
            .application(app)
            .title("AccuBattery")
            .default_width(740)
            .default_height(780)
            .content(&tb)
            .build();
        // narrow windows swap the header switcher for the bottom bar
        let cond = adw::BreakpointCondition::parse("max-width: 560sp").ok();
        if let Some(cond) = cond {
            let bp = adw::Breakpoint::new(cond);
            bp.add_setter(&bar, "reveal", Some(&true.to_value()));
            bp.add_setter(&header, "title-widget", Some(&None::<gtk::Widget>.to_value()));
            win.add_breakpoint(bp);
        }
        ui.set_window(&win);

        let (tx, rx) = async_channel::unbounded();
        let poll = {
            let tx = tx.clone();
            move || {
                let tx = tx.clone();
                std::thread::spawn(move || {
                    if let Some(bat) = Battery::find() {
                        let _ = tx.send_blocking(data::snapshot(&bat));
                    }
                });
            }
        };
        poll();
        glib::timeout_add_local(Duration::from_secs(3), move || {
            poll();
            glib::ControlFlow::Continue
        });
        let ui2: Rc<ui::Ui> = ui.clone();
        glib::spawn_future_local(async move {
            while let Ok(snap) = rx.recv().await {
                ui2.update(&snap);
            }
        });
        win.present();
    });
    app.run()
}
