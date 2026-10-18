//! lab-inject: presses keys and moves the mouse on this machine through the wlroots virtual input
//! protocols, which any Wayland client may use, so nothing needs extra privileges.
//! Reads one JSON command per line on stdin:
//!   {"m":[x,y,w,h]}   move the pointer to x,y inside a layout of w by h
//!   {"b":[code,1|0]}  mouse button, evdev code (272 is the left button), 1 is down
//!   {"a":[dx,dy]}     scroll, positive is down or right
//!   {"k":[code,1|0]}  key, evdev code, 1 is down
//! Keys use the keymap of the real keyboard, so the layout matches without any setup.

use std::io::{stdin, BufRead};
use std::os::fd::{AsFd, OwnedFd};
use std::process::ExitCode;
use std::time::Instant;

use serde_json::Value;
use wayland_client::{
    delegate_noop,
    globals::{registry_queue_init, GlobalListContents},
    protocol::{wl_keyboard, wl_pointer, wl_registry, wl_seat},
    Connection, Dispatch, QueueHandle, WEnum,
};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1,
    zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
};
use wayland_protocols_wlr::virtual_pointer::v1::client::{
    zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1,
    zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1,
};

struct State {
    keymap: Option<(u32, OwnedFd, u32)>,
    has_keyboard: bool,
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(
        _: &mut Self,
        _: &wl_registry::WlRegistry,
        _: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(
        state: &mut Self,
        _: &wl_seat::WlSeat,
        event: wl_seat::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_seat::Event::Capabilities {
            capabilities: WEnum::Value(caps),
        } = event
        {
            state.has_keyboard = caps.contains(wl_seat::Capability::Keyboard);
        }
    }
}

impl Dispatch<wl_keyboard::WlKeyboard, ()> for State {
    fn event(
        state: &mut Self,
        _: &wl_keyboard::WlKeyboard,
        event: wl_keyboard::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_keyboard::Event::Keymap { format, fd, size } = event {
            if let WEnum::Value(f) = format {
                state.keymap = Some((f as u32, fd, size));
            }
        }
    }
}

delegate_noop!(State: ZwlrVirtualPointerManagerV1);
delegate_noop!(State: ZwlrVirtualPointerV1);
delegate_noop!(State: ZwpVirtualKeyboardManagerV1);
delegate_noop!(State: ZwpVirtualKeyboardV1);

/// evdev key code to the xkb modifier bit it holds, for the usual evdev keymaps.
fn modifier_bit(code: u32) -> u32 {
    match code {
        42 | 54 => 1,    // shift
        29 | 97 => 4,    // control
        56 => 8,         // left alt
        100 => 128,      // right alt (AltGr, level 3)
        125 | 126 => 64, // super
        _ => 0,
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let conn = Connection::connect_to_env()?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn)?;
    let qh = queue.handle();
    let seat: wl_seat::WlSeat = globals.bind(&qh, 1..=7, ())?;
    let pointer_manager: ZwlrVirtualPointerManagerV1 = globals.bind(&qh, 1..=2, ())?;
    let keyboard_manager: ZwpVirtualKeyboardManagerV1 = globals.bind(&qh, 1..=1, ())?;
    let mut state = State {
        keymap: None,
        has_keyboard: false,
    };
    queue.roundtrip(&mut state)?;
    // no real keyboard (a headless compositor) means no keymap to copy, so keys are skipped
    let _real_keyboard = state.has_keyboard.then(|| seat.get_keyboard(&qh, ()));
    queue.roundtrip(&mut state)?;
    queue.roundtrip(&mut state)?;

    let pointer = pointer_manager.create_virtual_pointer(Some(&seat), &qh, ());
    let keyboard = match &state.keymap {
        Some((format, fd, size)) => {
            let k = keyboard_manager.create_virtual_keyboard(&seat, &qh, ());
            k.keymap(*format, fd.as_fd(), *size);
            Some(k)
        }
        None => {
            eprintln!("lab-inject: no keyboard on this seat, keys are ignored");
            None
        }
    };
    conn.flush()?;

    let start = Instant::now();
    let mut held_mods = 0u32;
    for line in stdin().lock().lines() {
        let Ok(cmd) = serde_json::from_str::<Value>(&line?) else {
            continue;
        };
        let t = start.elapsed().as_millis() as u32;
        let num = |v: &Value, i: usize| v[i].as_f64().unwrap_or(0.0);
        if let Some(m) = cmd.get("m") {
            pointer.motion_absolute(
                t,
                num(m, 0) as u32,
                num(m, 1) as u32,
                num(m, 2) as u32,
                num(m, 3) as u32,
            );
            pointer.frame();
        } else if let Some(b) = cmd.get("b") {
            let state = if num(b, 1) > 0.5 {
                wl_pointer::ButtonState::Pressed
            } else {
                wl_pointer::ButtonState::Released
            };
            pointer.button(t, num(b, 0) as u32, state);
            pointer.frame();
        } else if let Some(a) = cmd.get("a") {
            pointer.axis_source(wl_pointer::AxisSource::Wheel);
            for (axis, v) in [
                (wl_pointer::Axis::HorizontalScroll, num(a, 0)),
                (wl_pointer::Axis::VerticalScroll, num(a, 1)),
            ] {
                if v != 0.0 {
                    pointer.axis_discrete(
                        t,
                        axis,
                        v * 15.0,
                        v.signum() as i32 * (v.abs().ceil() as i32),
                    );
                }
            }
            pointer.frame();
        } else if let Some(k) = cmd.get("k") {
            let code = num(k, 0) as u32;
            let down = num(k, 1) > 0.5;
            let Some(keyboard) = &keyboard else { continue };
            keyboard.key(t, code, u32::from(down));
            let bit = modifier_bit(code);
            if bit != 0 {
                if down {
                    held_mods |= bit;
                } else {
                    held_mods &= !bit;
                }
                keyboard.modifiers(held_mods, 0, 0, 0);
            }
        }
        conn.flush()?;
    }
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("lab-inject: {e}");
            ExitCode::FAILURE
        }
    }
}
