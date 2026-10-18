//! lab-capture ADDRESS [--header-fd N]: raw frames of one window, taken from the window itself.
//!
//! Uses Hyprland's toplevel export protocol, so the picture is the window's own surface with its
//! subsurfaces and popups: other windows on top of it, other workspaces and the layout around it
//! do not show up, and neither do borders or rounded corners. ADDRESS is the `address` of
//! `hyprctl clients`, the protocol takes its low 32 bits. Frames go to stdout as bare BGRA; the first line on the header descriptor
//! (default 3, stderr when it is not open) is `WIDTH HEIGHT PIXFMT`, so a caller can pipe stdout
//! straight into an encoder without touching the pixels.
//!
//! Only changed frames are sent. Hyprland completes a request when it renders the window, and that
//! happens only when something changed, so after 40 ms of quiet the last frame is sent once more to let
//! a decoder that holds the newest frame release it. The first frame of an idle window needs the compositor
//! to render once, the caller nudges it (hyprctl dispatch dpms on).
//! Exit codes: 0 stdout closed, 3 the window changed size (start again).

use std::fs::File;
use std::io::Write;
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::process::ExitCode;
use std::time::Duration;

use wayland_client::{
    delegate_noop,
    globals::{registry_queue_init, GlobalListContents},
    protocol::{wl_buffer, wl_registry, wl_shm, wl_shm_pool},
    Connection, Dispatch, QueueHandle, WEnum,
};

mod export {
    use wayland_client;
    use wayland_client::protocol::*;

    pub mod __interfaces {
        use wayland_client::protocol::__interfaces::*;
        wayland_scanner::generate_interfaces!("protocols/hyprland-toplevel-export-v1.xml");
    }
    use self::__interfaces::*;
    wayland_scanner::generate_client_code!("protocols/hyprland-toplevel-export-v1.xml");
}
use export::hyprland_toplevel_export_frame_v1::{self, HyprlandToplevelExportFrameV1};
use export::hyprland_toplevel_export_manager_v1::HyprlandToplevelExportManagerV1;

const KICK_AFTER: Duration = Duration::from_millis(40);
const RETRY: Duration = Duration::from_millis(200);

#[derive(Default)]
struct State {
    /// format, width, height, stride of the frame being captured
    shape: Option<(u32, u32, u32, u32)>,
    result: Option<bool>,
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

impl Dispatch<HyprlandToplevelExportFrameV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &HyprlandToplevelExportFrameV1,
        event: hyprland_toplevel_export_frame_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        use hyprland_toplevel_export_frame_v1::Event;
        match event {
            Event::Buffer {
                format,
                width,
                height,
                stride,
            } => {
                if let WEnum::Value(f) = format {
                    state.shape = Some((f as u32, width, height, stride));
                }
            }
            Event::Ready { .. } => state.result = Some(true),
            Event::Failed => state.result = Some(false),
            _ => {}
        }
    }
}

delegate_noop!(State: HyprlandToplevelExportManagerV1);
delegate_noop!(State: ignore wl_shm::WlShm);
delegate_noop!(State: wl_shm_pool::WlShmPool);
delegate_noop!(State: ignore wl_buffer::WlBuffer);

struct Shared {
    buffer: wl_buffer::WlBuffer,
    ptr: *const u8,
    len: usize,
}

fn make_buffer(
    shm: &wl_shm::WlShm,
    qh: &QueueHandle<State>,
    shape: (u32, u32, u32, u32),
) -> Result<Shared, Box<dyn std::error::Error>> {
    let (format, w, h, stride) = shape;
    let len = (stride * h) as usize;
    let format = wl_shm::Format::try_from(format).map_err(|_| "unknown shm format")?;
    // SAFETY: plain libc calls on a fresh memfd that only this process owns.
    unsafe {
        let fd = libc::memfd_create(c"lab-capture".as_ptr(), 0);
        if fd < 0 || libc::ftruncate(fd, len as i64) != 0 {
            return Err("memfd failed".into());
        }
        let ptr = libc::mmap(
            std::ptr::null_mut(),
            len,
            libc::PROT_READ,
            libc::MAP_SHARED,
            fd,
            0,
        );
        if ptr == libc::MAP_FAILED {
            return Err("mmap failed".into());
        }
        let owned = OwnedFd::from_raw_fd(fd);
        let pool = shm.create_pool(owned.as_fd(), len as i32, qh, ());
        let buffer = pool.create_buffer(0, w as i32, h as i32, stride as i32, format, qh, ());
        pool.destroy();
        Ok(Shared {
            buffer,
            ptr: ptr as *const u8,
            len,
        })
    }
}

fn pixfmt(format: u32) -> &'static str {
    if format == wl_shm::Format::Xrgb8888 as u32 {
        "bgr0"
    } else {
        "bgra"
    }
}

/// Waits for the frame to finish. None on timeout.
fn wait_result(
    state: &mut State,
    queue: &mut wayland_client::EventQueue<State>,
    timeout: Option<Duration>,
) -> Result<Option<bool>, Box<dyn std::error::Error>> {
    let deadline = timeout.map(|t| std::time::Instant::now() + t);
    loop {
        queue.dispatch_pending(state)?;
        if let Some(r) = state.result.take() {
            return Ok(Some(r));
        }
        let ms = match deadline {
            Some(d) => match d.checked_duration_since(std::time::Instant::now()) {
                Some(left) => left.as_millis() as i32,
                None => return Ok(None),
            },
            None => -1,
        };
        queue.flush()?;
        if let Some(guard) = queue.prepare_read() {
            let mut pfd = libc::pollfd {
                fd: guard.connection_fd().as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: one valid pollfd.
            let n = unsafe { libc::poll(&mut pfd, 1, ms) };
            if n > 0 {
                guard.read()?;
            } else {
                drop(guard);
                if n == 0 && deadline.is_some() {
                    return Ok(None);
                }
            }
        }
    }
}

fn run(stable: u32, header_fd: i32) -> Result<u8, Box<dyn std::error::Error>> {
    let conn = Connection::connect_to_env()?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn)?;
    let qh = queue.handle();
    let manager: HyprlandToplevelExportManagerV1 = globals.bind(&qh, 1..=2, ())?;
    let shm: wl_shm::WlShm = globals.bind(&qh, 1..=1, ())?;
    let mut state = State::default();
    let mut out = unsafe { File::from_raw_fd(1) };

    let mut size: Option<(u32, u32)> = None;
    let mut buffers: Vec<Shared> = Vec::new();
    let (mut cur, mut have_prev, mut need_kick) = (0usize, false, false);
    loop {
        let frame = manager.capture_toplevel(0, stable, &qh, ());
        state.shape = None;
        state.result = None;
        // the buffer event arrives right after the request
        let mut waited = 0;
        while state.shape.is_none() && waited < 20 {
            queue.roundtrip(&mut state)?;
            waited += 1;
        }
        let Some(shape) = state.shape else {
            frame.destroy();
            std::thread::sleep(RETRY);
            continue;
        };
        match size {
            None => {
                size = Some((shape.1, shape.2));
                buffers = vec![
                    make_buffer(&shm, &qh, shape)?,
                    make_buffer(&shm, &qh, shape)?,
                ];
                let mut header: Box<dyn Write> =
                    if unsafe { libc::fcntl(header_fd, libc::F_GETFD) } >= 0 {
                        Box::new(unsafe { File::from_raw_fd(header_fd) })
                    } else {
                        Box::new(std::io::stderr())
                    };
                writeln!(header, "{} {} {}", shape.1, shape.2, pixfmt(shape.0))?;
                header.flush()?;
            }
            Some(s) if s != (shape.1, shape.2) => {
                frame.destroy();
                return Ok(3);
            }
            _ => {}
        }
        // the request stays pending until the compositor renders the window, which only happens when
        // something changed. After a short quiet the last frame is sent once more, see the header.
        frame.copy(&buffers[cur].buffer, 1);
        let mut kicked = !need_kick;
        let outcome = loop {
            let wait = if kicked { None } else { Some(KICK_AFTER) };
            match wait_result(&mut state, &mut queue, wait)? {
                None => {
                    kicked = true;
                    need_kick = false;
                    let last = &buffers[1 - cur];
                    // SAFETY: the mapping is len bytes long and lives as long as the process.
                    let px = unsafe { std::slice::from_raw_parts(last.ptr, last.len) };
                    if out.write_all(px).is_err() {
                        return Ok(0);
                    }
                }
                done => break done,
            }
        };
        frame.destroy();
        if outcome != Some(true) {
            std::thread::sleep(RETRY);
            have_prev = false;
            continue;
        }
        let (new, old) = (&buffers[cur], &buffers[1 - cur]);
        // SAFETY: both mappings are len bytes long and live as long as the process.
        let (new_px, old_px) = unsafe {
            (
                std::slice::from_raw_parts(new.ptr, new.len),
                std::slice::from_raw_parts(old.ptr, old.len),
            )
        };
        if !have_prev || new_px != old_px {
            if out.write_all(new_px).is_err() {
                return Ok(0);
            }
            need_kick = true;
        }
        have_prev = true;
        cur = 1 - cur;
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(stable) = args
        .first()
        .and_then(|s| u64::from_str_radix(s.trim_start_matches("0x"), 16).ok())
        .map(|a| (a & 0xffff_ffff) as u32)
    else {
        eprintln!("usage: lab-capture ADDRESS [--header-fd N]");
        return ExitCode::from(64);
    };
    let header_fd = args
        .iter()
        .position(|a| a == "--header-fd")
        .and_then(|i| args.get(i + 1))
        .and_then(|v| v.parse().ok())
        .unwrap_or(3);
    match run(stable, header_fd) {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("lab-capture: {e}");
            ExitCode::FAILURE
        }
    }
}
