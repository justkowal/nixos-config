//! One cairo chart for everything: a primary line (percent or health) with an optional
//! filled secondary series (watts) on the right axis.

use std::cell::RefCell;
use std::rc::Rc;

use gtk::prelude::*;
use gtk4 as gtk;
use gtk4::{gdk, glib, pango};
use libadwaita as adw;

#[derive(Default, Clone)]
pub struct Series {
    /// dashed continuation of the primary line, same axes
    pub projection: Vec<(f64, f64)>,
    /// p10 and p90 curves of the forecast, shaded between
    pub band: Option<(Vec<(f64, f64)>, Vec<(f64, f64)>)>,
    /// intervals the laptop is expected to be asleep or off
    pub strips: Vec<(f64, f64)>,
    pub primary: Vec<(f64, f64)>,
    pub secondary: Vec<(f64, f64)>,
    /// fixed range for the primary axis; None fits the data
    pub range: Option<(f64, f64)>,
    pub unit: &'static str,
    /// color name from the theme: success, warning, accent
    pub tone: &'static str,
}

#[derive(Clone)]
pub struct Graph {
    pub area: gtk::DrawingArea,
    data: Rc<RefCell<Series>>,
}

thread_local! {
    static STYLE: crate::tokens::Style = crate::tokens::load();
}

const ML: f64 = 44.0;
const MR: f64 = 44.0;
const MT: f64 = 10.0;
const MB: f64 = 24.0;

fn rgba(c: &gdk::RGBA, a: f64) -> (f64, f64, f64, f64) {
    (c.red() as f64, c.green() as f64, c.blue() as f64, a)
}

#[allow(deprecated)]
fn tone(area: &gtk::DrawingArea, name: &str) -> gdk::RGBA {
    if name == "accent" {
        return adw::StyleManager::default().accent_color_rgba();
    }
    area.style_context()
        .lookup_color(&format!("{name}_color"))
        .unwrap_or_else(|| adw::StyleManager::default().accent_color_rgba())
}

fn label(area: &gtk::DrawingArea, cr: &gtk::cairo::Context, text: &str, x: f64, y: f64, align: f64) {
    let l = area.create_pango_layout(Some(text));
    let attrs = pango::AttrList::new();
    let pt = STYLE.with(|s| s.caption_pt * 1.15);
    attrs.insert(pango::AttrSize::new((pt * pango::SCALE as f64) as i32));
    l.set_attributes(Some(&attrs));
    let (w, h) = l.pixel_size();
    cr.move_to(x - w as f64 * align, y - h as f64 / 2.0);
    pangocairo::functions::show_layout(cr, &l);
}

fn clock(t: f64) -> String {
    glib::DateTime::from_unix_local(t as i64)
        .ok()
        .and_then(|d| d.format("%H:%M").ok())
        .map(|s| s.to_string())
        .unwrap_or_default()
}

impl Graph {
    pub fn new(height: i32) -> Self {
        let area = gtk::DrawingArea::builder().content_height(height).hexpand(true).build();
        let data = Rc::new(RefCell::new(Series::default()));
        let d = data.clone();
        let a = area.clone();
        area.set_draw_func(move |_, cr, w, h| draw(&a, &d.borrow(), cr, w as f64, h as f64));
        Self { area, data }
    }

    pub fn set(&self, s: Series) {
        *self.data.borrow_mut() = s;
        self.area.queue_draw();
    }
}

fn draw(area: &gtk::DrawingArea, s: &Series, cr: &gtk::cairo::Context, w: f64, h: f64) {
    let fg = area.color();
    let line = tone(area, s.tone);
    let (pw, ph) = (w - ML - MR, h - MT - MB);
    if pw <= 0.0 || ph <= 0.0 || s.primary.len() < 2 {
        cr.set_source_rgba(fg.red() as f64, fg.green() as f64, fg.blue() as f64, 0.5);
        label(area, cr, "Collecting data", w / 2.0, h / 2.0, 0.5);
        return;
    }

    let (t0, t1) = (s.primary[0].0, s.projection.last().map_or(s.primary[s.primary.len() - 1].0, |p| p.0));
    let tspan = (t1 - t0).max(1.0);
    let (lo, hi) = s.range.unwrap_or_else(|| {
        let all = s.primary.iter().chain(s.projection.iter()).map(|p| p.1);
        let lo = all.clone().fold(f64::MAX, f64::min);
        let hi = all.fold(f64::MIN, f64::max);
        let pad = ((hi - lo) * 0.15).max(0.5);
        (lo - pad, hi + pad)
    });
    let x = |t: f64| ML + (t - t0) / tspan * pw;
    let y = |v: f64| MT + ph - (v - lo) / (hi - lo).max(1e-6) * ph;

    for (a, b) in &s.strips {
        let (xa, xb) = (x(a.max(t0)), x(b.min(t1)));
        if xb > xa {
            cr.set_source_rgba(fg.red() as f64, fg.green() as f64, fg.blue() as f64, 0.07);
            cr.rectangle(xa, MT, xb - xa, ph);
            let _ = cr.fill();
            cr.set_source_rgba(fg.red() as f64, fg.green() as f64, fg.blue() as f64, 0.5);
            if xb - xa > 46.0 {
                label(area, cr, "asleep", xa + 4.0, MT + 8.0, 0.0);
            }
        }
    }
    if let Some((lo_c, hi_c)) = &s.band {
        if lo_c.len() >= 2 && lo_c.len() == hi_c.len() {
            let c = rgba(&line, 0.14);
            cr.set_source_rgba(c.0, c.1, c.2, c.3);
            cr.move_to(x(hi_c[0].0), y(hi_c[0].1));
            for p in hi_c {
                cr.line_to(x(p.0), y(p.1));
            }
            for p in lo_c.iter().rev() {
                cr.line_to(x(p.0), y(p.1));
            }
            cr.close_path();
            let _ = cr.fill();
        }
    }

    cr.set_line_width(1.0);
    for i in 0..=4 {
        let v = lo + (hi - lo) * i as f64 / 4.0;
        let yy = y(v).round() + 0.5;
        cr.set_source_rgba(fg.red() as f64, fg.green() as f64, fg.blue() as f64, 0.12);
        cr.move_to(ML, yy);
        cr.line_to(w - MR, yy);
        let _ = cr.stroke();
        cr.set_source_rgba(fg.red() as f64, fg.green() as f64, fg.blue() as f64, 0.6);
        label(area, cr, &format!("{v:.0}{}", s.unit), ML - 6.0, yy, 1.0);
    }
    label(area, cr, &clock(t0), ML, h - MB / 2.0, 0.0);
    label(area, cr, &clock(t1), w - MR, h - MB / 2.0, 1.0);

    if s.secondary.len() >= 2 {
        let wmax = s.secondary.iter().map(|p| p.1).fold(1.0, f64::max) * 1.1;
        let yw = |v: f64| MT + ph - v / wmax * ph;
        let c = rgba(&line, 0.18);
        cr.set_source_rgba(c.0, c.1, c.2, c.3);
        cr.move_to(x(s.secondary[0].0), MT + ph);
        for p in &s.secondary {
            cr.line_to(x(p.0), yw(p.1));
        }
        cr.line_to(x(s.secondary[s.secondary.len() - 1].0), MT + ph);
        cr.close_path();
        let _ = cr.fill();
        cr.set_source_rgba(fg.red() as f64, fg.green() as f64, fg.blue() as f64, 0.6);
        label(area, cr, &format!("{wmax:.0} W"), w - MR + 6.0, MT + 4.0, 0.0);
    }

    let c = rgba(&line, 1.0);
    cr.set_source_rgba(c.0, c.1, c.2, c.3);
    let lw = STYLE.with(|s| s.line_px);
    cr.set_line_width(lw);
    cr.set_line_join(gtk::cairo::LineJoin::Round);
    for (i, p) in s.primary.iter().enumerate() {
        if i == 0 {
            cr.move_to(x(p.0), y(p.1));
        } else {
            cr.line_to(x(p.0), y(p.1));
        }
    }
    let _ = cr.stroke();
    if s.projection.len() >= 2 {
        cr.set_dash(&[6.0, 5.0], 0.0);
        cr.set_source_rgba(c.0, c.1, c.2, 0.7);
        for (i, p) in s.projection.iter().enumerate() {
            if i == 0 {
                cr.move_to(x(p.0), y(p.1));
            } else {
                cr.line_to(x(p.0), y(p.1));
            }
        }
        let _ = cr.stroke();
        cr.set_dash(&[], 0.0);
        cr.set_source_rgba(c.0, c.1, c.2, c.3);
    }
    let last = s.primary[s.primary.len() - 1];
    cr.arc(x(last.0), y(last.1), 3.5, 0.0, std::f64::consts::TAU);
    let _ = cr.fill();
}
