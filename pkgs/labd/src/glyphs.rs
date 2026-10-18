//! The Lab glyph set, drawn with cairo in a 24x24 box (round caps, 1.75 stroke).
//! Drawn instead of loaded so the island never depends on whichever icon theme is active,
//! and so every state shares one stroke weight.

use std::cell::Cell;
use std::f64::consts::PI;
use std::rc::Rc;

use gtk4::cairo::{Context, LineCap, LineJoin};
use gtk4::prelude::*;

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Glyph {
    /// 0 = speaker only, 1 = one wave, 2 = two waves
    Volume(u8),
    Muted,
    Mic,
    MicOff,
    Brightness,
    FocusOn,
    FocusOff,
    Room,
    Handoff,
    Action,
    Power,
    Lock,
    Search,
    Scene,
    Device,
    Dot,
    Ring,
    Battery,
    /// 0 to 4 segments, charging draws a bolt
    BatteryLevel(u8, bool),
    /// 0 to 3 arcs
    Wifi(u8),
    WifiOff,
    Ethernet,
    Bluetooth,
    Bell,
    BellDot,
    BellOff,
    Sliders,
    Timer,
    Cup,
    Dial,
    Note,
    Fingerprint,
    Clipboard,
    /// a rotating arc, the frame 0 to 11 sets the angle
    Spinner(u8),
    Check,
}

pub const SIZE: f64 = 24.0;

fn line(cr: &Context, pts: &[(f64, f64)]) {
    cr.move_to(pts[0].0, pts[0].1);
    for p in &pts[1..] {
        cr.line_to(p.0, p.1);
    }
}

fn speaker(cr: &Context) {
    line(
        cr,
        &[
            (11.0, 5.0),
            (6.0, 9.0),
            (2.0, 9.0),
            (2.0, 15.0),
            (6.0, 15.0),
            (11.0, 19.0),
        ],
    );
    cr.close_path();
}

fn mic(cr: &Context) {
    cr.arc(12.0, 6.0, 3.0, PI, 0.0);
    cr.arc(12.0, 10.0, 3.0, 0.0, PI);
    cr.close_path();
    cr.new_sub_path();
    cr.arc(12.0, 11.0, 7.0, 0.0, PI);
    line(cr, &[(12.0, 18.0), (12.0, 22.0)]);
}

/// Strokes the glyph with the current source colour.
pub fn draw(cr: &Context, glyph: Glyph) {
    cr.set_line_width(1.75);
    cr.set_line_cap(LineCap::Round);
    cr.set_line_join(LineJoin::Round);
    match glyph {
        Glyph::Volume(level) => {
            speaker(cr);
            for (i, r) in [4.0, 7.5].iter().enumerate() {
                if usize::from(level) > i {
                    cr.new_sub_path();
                    cr.arc(11.0, 12.0, *r, -0.62, 0.62);
                }
            }
        }
        Glyph::Muted => {
            speaker(cr);
            line(cr, &[(16.0, 9.0), (22.0, 15.0)]);
            line(cr, &[(22.0, 9.0), (16.0, 15.0)]);
        }
        Glyph::Mic => mic(cr),
        Glyph::MicOff => {
            mic(cr);
            line(cr, &[(3.0, 3.0), (21.0, 21.0)]);
        }
        Glyph::Brightness => {
            cr.arc(12.0, 12.0, 4.0, 0.0, 2.0 * PI);
            for i in 0..8 {
                let a = f64::from(i) * PI / 4.0;
                cr.new_sub_path();
                cr.move_to(12.0 + 7.0 * a.cos(), 12.0 + 7.0 * a.sin());
                cr.line_to(12.0 + 9.5 * a.cos(), 12.0 + 9.5 * a.sin());
            }
        }
        Glyph::FocusOn | Glyph::FocusOff => {
            line(cr, &[(3.0, 8.0), (3.0, 3.0), (8.0, 3.0)]);
            line(cr, &[(16.0, 3.0), (21.0, 3.0), (21.0, 8.0)]);
            line(cr, &[(21.0, 16.0), (21.0, 21.0), (16.0, 21.0)]);
            line(cr, &[(8.0, 21.0), (3.0, 21.0), (3.0, 16.0)]);
            if glyph == Glyph::FocusOn {
                // stroke the brackets, then the dot is filled separately below
                let _ = cr.stroke();
                cr.arc(12.0, 12.0, 3.0, 0.0, 2.0 * PI);
                let _ = cr.fill();
                return;
            }
        }
        Glyph::Room => {
            for (x, y) in [(3.0, 3.0), (14.0, 3.0), (3.0, 14.0), (14.0, 14.0)] {
                cr.rectangle(x, y, 7.0, 7.0);
            }
        }
        Glyph::Action => {
            line(cr, &[(4.0, 7.0), (10.0, 12.0), (4.0, 17.0)]);
            line(cr, &[(13.0, 18.0), (20.0, 18.0)]);
        }
        Glyph::Power => {
            cr.arc(12.0, 13.0, 8.0, -PI / 2.0 + 0.55, 1.5 * PI - 0.55);
            line(cr, &[(12.0, 3.0), (12.0, 12.0)]);
        }
        Glyph::Lock => {
            cr.rectangle(5.0, 11.0, 14.0, 10.0);
            cr.move_to(8.0, 11.0);
            cr.line_to(8.0, 8.0);
            cr.arc(12.0, 8.0, 4.0, PI, 0.0);
            cr.line_to(16.0, 11.0);
        }
        Glyph::Search => {
            cr.arc(10.0, 10.0, 6.5, 0.0, 2.0 * PI);
            line(cr, &[(15.0, 15.0), (21.0, 21.0)]);
        }
        Glyph::Scene => {
            line(
                cr,
                &[
                    (12.0, 3.0),
                    (14.0, 10.0),
                    (21.0, 12.0),
                    (14.0, 14.0),
                    (12.0, 21.0),
                    (10.0, 14.0),
                    (3.0, 12.0),
                    (10.0, 10.0),
                ],
            );
            cr.close_path();
        }
        Glyph::Device => {
            cr.rectangle(3.0, 4.0, 18.0, 12.0);
            line(cr, &[(8.0, 20.0), (16.0, 20.0)]);
            line(cr, &[(12.0, 16.0), (12.0, 20.0)]);
        }
        Glyph::Dot => {
            cr.arc(12.0, 12.0, 7.0, 0.0, 2.0 * PI);
            let _ = cr.fill();
            return;
        }
        Glyph::Battery => {
            cr.rectangle(2.5, 7.5, 16.0, 9.0);
            line(cr, &[(21.0, 10.5), (21.0, 13.5)]);
            line(cr, &[(5.5, 12.0), (12.0, 12.0)]);
        }
        Glyph::Ring => {
            cr.arc(12.0, 12.0, 6.5, 0.0, 2.0 * PI);
        }
        Glyph::BatteryLevel(level, charging) => {
            cr.rectangle(2.0, 7.0, 17.0, 10.0);
            line(cr, &[(21.5, 10.5), (21.5, 13.5)]);
            let _ = cr.stroke();
            for i in 0..level.min(4) {
                cr.rectangle(4.0 + f64::from(i) * 3.6, 9.0, 3.0, 6.0);
            }
            let _ = cr.fill();
            if charging {
                line(
                    cr,
                    &[
                        (12.5, 9.0),
                        (8.5, 13.5),
                        (12.0, 13.5),
                        (11.0, 18.5),
                        (15.5, 12.5),
                        (12.0, 12.5),
                    ],
                );
                cr.close_path();
                cr.set_source_rgba(0.0, 0.0, 0.0, 0.0);
            }
            return;
        }
        Glyph::Wifi(strength) => {
            for (i, r) in [5.0, 9.0, 13.0].iter().enumerate() {
                if usize::from(strength) > i {
                    cr.new_sub_path();
                    cr.arc(12.0, 19.0, *r, -PI * 0.78, -PI * 0.22);
                }
            }
            let _ = cr.stroke();
            cr.arc(12.0, 19.0, 1.4, 0.0, 2.0 * PI);
            let _ = cr.fill();
            return;
        }
        Glyph::WifiOff => {
            cr.arc(12.0, 19.0, 5.0, -PI * 0.78, -PI * 0.22);
            line(cr, &[(4.0, 4.0), (20.0, 20.0)]);
        }
        Glyph::Ethernet => {
            cr.rectangle(5.0, 5.0, 14.0, 10.0);
            line(cr, &[(9.0, 15.0), (9.0, 19.0)]);
            line(cr, &[(12.0, 15.0), (12.0, 20.0)]);
            line(cr, &[(15.0, 15.0), (15.0, 19.0)]);
        }
        Glyph::Bluetooth => {
            line(
                cr,
                &[
                    (7.0, 7.5),
                    (17.0, 16.5),
                    (12.0, 21.0),
                    (12.0, 3.0),
                    (17.0, 7.5),
                    (7.0, 16.5),
                ],
            );
        }
        Glyph::Bell | Glyph::BellDot | Glyph::BellOff => {
            cr.move_to(6.0, 17.0);
            cr.line_to(6.0, 10.5);
            cr.arc(12.0, 10.5, 6.0, PI, 0.0);
            cr.line_to(18.0, 17.0);
            cr.close_path();
            cr.new_sub_path();
            cr.arc(12.0, 19.5, 1.8, 0.0, PI);
            if glyph == Glyph::BellOff {
                line(cr, &[(3.5, 3.5), (20.5, 20.5)]);
            }
            let _ = cr.stroke();
            if glyph == Glyph::BellDot {
                cr.arc(18.0, 5.5, 2.6, 0.0, 2.0 * PI);
                let _ = cr.fill();
            }
            return;
        }
        Glyph::Timer => {
            cr.arc(12.0, 13.5, 7.0, 0.0, 2.0 * PI);
            line(cr, &[(12.0, 13.5), (12.0, 9.5)]);
            line(cr, &[(10.0, 3.5), (14.0, 3.5)]);
            line(cr, &[(12.0, 3.5), (12.0, 6.5)]);
        }
        Glyph::Cup => {
            line(
                cr,
                &[
                    (5.0, 9.0),
                    (5.0, 15.0),
                    (8.0, 19.0),
                    (14.0, 19.0),
                    (17.0, 15.0),
                    (17.0, 9.0),
                ],
            );
            line(cr, &[(5.0, 9.0), (17.0, 9.0)]);
            cr.new_sub_path();
            cr.arc(17.5, 12.0, 3.0, -PI / 2.0, PI / 2.0);
            line(cr, &[(9.0, 3.5), (9.0, 6.0)]);
            line(cr, &[(13.0, 3.5), (13.0, 6.0)]);
        }
        Glyph::Dial => {
            cr.arc(12.0, 12.0, 8.0, 0.0, 2.0 * PI);
            cr.new_sub_path();
            cr.arc(12.0, 12.0, 3.0, 0.0, 2.0 * PI);
        }
        Glyph::Spinner(frame) => {
            let start = f64::from(frame % 12) * PI / 6.0;
            cr.arc(12.0, 12.0, 8.0, start, start + 1.5 * PI);
        }
        Glyph::Check => {
            line(cr, &[(5.5, 12.5), (10.0, 17.0), (18.5, 7.5)]);
        }
        Glyph::Clipboard => {
            cr.rectangle(5.0, 5.0, 14.0, 16.0);
            cr.new_sub_path();
            cr.rectangle(9.0, 3.0, 6.0, 4.0);
            line(cr, &[(8.5, 12.0), (15.5, 12.0)]);
            line(cr, &[(8.5, 16.0), (13.0, 16.0)]);
        }
        Glyph::Fingerprint => {
            // ridges as arcs open at the bottom, widest first
            for r in [9.5, 6.5, 3.5] {
                cr.new_sub_path();
                cr.arc(12.0, 12.0, r, 0.8 * PI, 2.2 * PI);
            }
            line(cr, &[(12.0, 12.0), (12.0, 17.0)]);
            line(cr, &[(8.5, 14.0), (8.5, 19.0)]);
            line(cr, &[(15.5, 14.0), (15.5, 20.5)]);
        }
        Glyph::Note => {
            line(cr, &[(9.0, 18.0), (9.0, 6.0), (18.0, 4.0), (18.0, 16.0)]);
            cr.new_sub_path();
            cr.arc(6.5, 18.0, 2.5, 0.0, 2.0 * PI);
            cr.new_sub_path();
            cr.arc(15.5, 16.0, 2.5, 0.0, 2.0 * PI);
        }
        Glyph::Sliders => {
            line(cr, &[(4.0, 7.0), (20.0, 7.0)]);
            line(cr, &[(4.0, 12.0), (20.0, 12.0)]);
            line(cr, &[(4.0, 17.0), (20.0, 17.0)]);
            cr.new_sub_path();
            cr.arc(9.0, 7.0, 2.2, 0.0, 2.0 * PI);
            cr.new_sub_path();
            cr.arc(15.0, 12.0, 2.2, 0.0, 2.0 * PI);
            cr.new_sub_path();
            cr.arc(9.0, 17.0, 2.2, 0.0, 2.0 * PI);
        }
        Glyph::Handoff => {
            line(cr, &[(4.0, 8.0), (20.0, 8.0)]);
            line(cr, &[(16.0, 4.0), (20.0, 8.0), (16.0, 12.0)]);
            line(cr, &[(20.0, 16.0), (4.0, 16.0)]);
            line(cr, &[(8.0, 12.0), (4.0, 16.0), (8.0, 20.0)]);
        }
    }
    let _ = cr.stroke();
}

/// A square drawing area that strokes the shared glyph in the widget's text colour.
pub fn area(glyph: &Rc<Cell<Glyph>>, px: i32) -> gtk4::DrawingArea {
    let area = gtk4::DrawingArea::builder()
        .content_width(px)
        .content_height(px)
        .valign(gtk4::Align::Center)
        .build();
    let glyph = glyph.clone();
    area.set_draw_func(move |area, cr, w, h| {
        let c = area.color();
        cr.set_source_rgba(
            f64::from(c.red()),
            f64::from(c.green()),
            f64::from(c.blue()),
            f64::from(c.alpha()),
        );
        cr.scale(f64::from(w) / SIZE, f64::from(h) / SIZE);
        draw(cr, glyph.get());
    });
    area
}

#[cfg(test)]
mod tests {
    use super::*;
    use gtk4::cairo::{Format, ImageSurface};

    /// Dev aid: `LAB_GLYPH_SHEET=/tmp/glyphs.png cargo test glyph_sheet -- --ignored`
    #[test]
    #[ignore]
    fn glyph_sheet() {
        let Ok(path) = std::env::var("LAB_GLYPH_SHEET") else {
            return;
        };
        let all = [
            Glyph::Volume(0),
            Glyph::Volume(1),
            Glyph::Volume(2),
            Glyph::Muted,
            Glyph::Mic,
            Glyph::MicOff,
            Glyph::Brightness,
            Glyph::FocusOn,
            Glyph::FocusOff,
            Glyph::Room,
            Glyph::Handoff,
            Glyph::Action,
            Glyph::Power,
            Glyph::Lock,
            Glyph::Search,
            Glyph::Scene,
            Glyph::Device,
            Glyph::Dot,
            Glyph::Ring,
            Glyph::Battery,
            Glyph::BatteryLevel(3, false),
            Glyph::BatteryLevel(2, true),
            Glyph::Wifi(3),
            Glyph::Wifi(1),
            Glyph::WifiOff,
            Glyph::Ethernet,
            Glyph::Bluetooth,
            Glyph::Bell,
            Glyph::BellDot,
            Glyph::BellOff,
            Glyph::Sliders,
            Glyph::Timer,
            Glyph::Cup,
            Glyph::Dial,
            Glyph::Note,
            Glyph::Fingerprint,
            Glyph::Clipboard,
            Glyph::Spinner(3),
            Glyph::Check,
        ];
        let cell = 96;
        let surface = ImageSurface::create(Format::ARgb32, cell * all.len() as i32, cell).unwrap();
        let cr = Context::new(&surface).unwrap();
        cr.set_source_rgb(0.12, 0.12, 0.13);
        cr.paint().unwrap();
        for (i, g) in all.iter().enumerate() {
            cr.save().unwrap();
            cr.translate(f64::from(i as i32 * cell) + 12.0, 12.0);
            cr.scale(72.0 / SIZE, 72.0 / SIZE);
            cr.set_source_rgb(0.93, 0.93, 0.93);
            draw(&cr, *g);
            cr.restore().unwrap();
        }
        let mut f = std::fs::File::create(path).unwrap();
        surface.write_to_png(&mut f).unwrap();
    }
}
