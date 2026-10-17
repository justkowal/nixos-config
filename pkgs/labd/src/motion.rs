//! One spring for every Lab surface. Surfaces animate a 0..1 progress value and apply it
//! themselves (opacity, margin), so the island and the palette move the same way.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;
use gtk4 as gtk;
use libadwaita as adw;

use crate::tokens::Tokens;

pub struct Motion {
    progress: Cell<f64>,
    anim: RefCell<Option<adw::SpringAnimation>>,
    reduced: bool,
    ratio: f64,
    mass: f64,
    stiffness: f64,
}

impl Motion {
    pub fn new(tokens: &Tokens) -> Rc<Self> {
        Rc::new(Motion {
            progress: Cell::new(0.0),
            anim: RefCell::new(None),
            reduced: tokens.reduced_motion,
            ratio: tokens.damping_ratio(),
            mass: tokens.mass,
            stiffness: tokens.stiffness,
        })
    }

    pub fn progress(&self) -> f64 {
        self.progress.get()
    }

    fn stop(&self) {
        // pausing drops the old animation's done callback, which is what we want when interrupted
        if let Some(old) = self.anim.borrow_mut().take() {
            old.pause();
        }
    }

    pub fn animate(
        self: &Rc<Self>,
        widget: &impl IsA<gtk::Widget>,
        to: f64,
        apply: impl Fn(f64) + 'static,
        on_done: impl Fn() + 'static,
    ) {
        self.stop();
        if self.reduced {
            self.progress.set(to);
            apply(to);
            on_done();
            return;
        }
        let me = Rc::downgrade(self);
        let target = adw::CallbackAnimationTarget::new(move |v| {
            if let Some(me) = me.upgrade() {
                me.progress.set(v);
            }
            apply(v);
        });
        let params = adw::SpringParams::new(self.ratio, self.mass, self.stiffness);
        let anim = adw::SpringAnimation::new(widget, self.progress.get(), to, params, target);
        anim.set_epsilon(0.002);
        anim.connect_done(move |_| on_done());
        anim.play();
        *self.anim.borrow_mut() = Some(anim);
    }
}
