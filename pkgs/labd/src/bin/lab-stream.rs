//! lab-stream ADDRESS: H.264 of one window with no CPU copy of the pixels.
//!
//! Hyprland renders the window straight into GPU buffers that this process allocated (GBM, linear)
//! and shared as DMA-BUF. They go into GStreamer's VA-API pipeline (`vapostproc` converts to NV12 on
//! the GPU, `vah264enc` encodes it) and only the small encoded bitstream reaches the CPU. The
//! alternative is lab-capture, which reads the pixels back to memory and needs ffmpeg to upload them
//! again; use that when this reports failure.
//!
//! Output on stdout is raw Annex B H.264. Exit codes: 0 stdout closed, 3 the window changed size
//! (start again), 4 this path is not available here (use lab-capture).
//!
//! The compositor completes a capture only when it renders the window, so after 40 ms of quiet the
//! last buffer is encoded once more to let the decoder on the other side release the newest frame.

use std::fs::File;
use std::io::Write;
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_allocators as gst_alloc;
use gstreamer_allocators::prelude::*;
use gstreamer_app as gst_app;
use gstreamer_video as gst_video;
use wayland_client::{
    delegate_noop,
    globals::{registry_queue_init, GlobalListContents},
    protocol::{wl_buffer, wl_registry},
    Connection, Dispatch, QueueHandle, WEnum,
};
use wayland_protocols::wp::linux_dmabuf::zv1::client::{
    zwp_linux_buffer_params_v1::{Flags, ZwpLinuxBufferParamsV1},
    zwp_linux_dmabuf_v1::ZwpLinuxDmabufV1,
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

/// Lowers `max_dec_frame_buffering` in an SPS to the smallest legal value. The VA-API decoder holds
/// that many frames back before showing them, and the VA-API encoder asks for one more than needed.
/// Only baseline and main style SPS (no chroma fields) with a VUI are handled, anything else is left alone.
mod sps {
    struct Bits<'a> {
        data: &'a [u8],
        pos: usize,
    }

    impl Bits<'_> {
        fn bit(&mut self) -> Option<u32> {
            let b = *self.data.get(self.pos / 8)?;
            let v = (b >> (7 - self.pos % 8)) & 1;
            self.pos += 1;
            Some(u32::from(v))
        }
        fn bits(&mut self, n: usize) -> Option<u32> {
            let mut v = 0;
            for _ in 0..n {
                v = (v << 1) | self.bit()?;
            }
            Some(v)
        }
        fn ue(&mut self) -> Option<u32> {
            let mut zeros = 0;
            while self.bit()? == 0 {
                zeros += 1;
                if zeros > 31 {
                    return None;
                }
            }
            Some((1 << zeros) - 1 + self.bits(zeros)?)
        }
        fn se(&mut self) -> Option<()> {
            self.ue().map(|_| ())
        }
    }

    fn unescape(nal: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(nal.len());
        let mut zeros = 0;
        for &b in nal {
            if zeros >= 2 && b == 3 {
                zeros = 0;
                continue;
            }
            zeros = if b == 0 { zeros + 1 } else { 0 };
            out.push(b);
        }
        out
    }

    fn escape(rbsp: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(rbsp.len() + 4);
        let mut zeros = 0;
        for &b in rbsp {
            if zeros >= 2 && b <= 3 {
                out.push(3);
                zeros = 0;
            }
            zeros = if b == 0 { zeros + 1 } else { 0 };
            out.push(b);
        }
        out
    }

    /// Bit positions in the SPS: the video_signal_type_present_flag and its value, then max_dec_frame_buffering,
    /// its value, and max_num_ref_frames.
    struct Found {
        signal_flag: (usize, bool),
        dpb: (usize, u32),
        refs: u32,
    }

    fn locate(rbsp: &[u8]) -> Option<Found> {
        let mut r = Bits { data: rbsp, pos: 8 }; // after the NAL header byte
        let profile = r.bits(8)?;
        if !matches!(profile, 66 | 77 | 88) {
            return None;
        }
        r.bits(16)?; // constraint flags and level
        r.ue()?; // sps id
        r.ue()?; // log2_max_frame_num
        match r.ue()? {
            0 => {
                r.ue()?;
            }
            1 => {
                r.bit()?;
                r.se()?;
                r.se()?;
                for _ in 0..r.ue()? {
                    r.se()?;
                }
            }
            _ => {}
        }
        let refs = r.ue()?;
        r.bit()?; // gaps
        r.ue()?;
        r.ue()?;
        if r.bit()? == 0 {
            r.bit()?;
        }
        r.bit()?; // direct 8x8
        if r.bit()? == 1 {
            for _ in 0..4 {
                r.ue()?;
            }
        }
        if r.bit()? == 0 {
            return None; // no VUI
        }
        if r.bit()? == 1 && r.bits(8)? == 255 {
            r.bits(32)?; // sar
        }
        if r.bit()? == 1 {
            r.bit()?;
        }
        let signal_at = r.pos;
        let signal = r.bit()? == 1;
        if signal {
            r.bits(4)?;
            if r.bit()? == 1 {
                r.bits(24)?;
            }
        }
        if r.bit()? == 1 {
            r.ue()?;
            r.ue()?;
        }
        if r.bit()? == 1 {
            r.bits(32)?;
            r.bits(32)?;
            r.bit()?;
        }
        if r.bit()? == 1 || r.bit()? == 1 {
            return None; // HRD parameters, not written by the encoders in use
        }
        r.bit()?; // pic_struct_present
        if r.bit()? == 0 {
            return None; // no bitstream restriction
        }
        r.bit()?;
        for _ in 0..4 {
            r.ue()?;
        }
        r.ue()?; // max_num_reorder_frames
        let at = r.pos;
        Some(Found {
            signal_flag: (signal_at, signal),
            dpb: (at, r.ue()?),
            refs,
        })
    }

    fn unpack(rbsp: &[u8]) -> Vec<bool> {
        rbsp.iter()
            .flat_map(|b| (0..8).rev().map(move |i| (b >> i) & 1 == 1))
            .collect()
    }

    fn pack(mut bits: Vec<bool>) -> Vec<u8> {
        // the closing bit, then zeros up to a byte boundary
        bits.push(true);
        while bits.len() % 8 != 0 {
            bits.push(false);
        }
        bits.chunks(8)
            .map(|c| c.iter().fold(0u8, |a, &b| (a << 1) | u8::from(b)))
            .collect()
    }

    /// The NAL unit (without start code) with two changes: the decoder buffer is lowered to the smallest legal
    /// size, and the colour is declared (BT.709, limited range) when the encoder left it out, because a decoder
    /// that has to guess treats limited range data as full range and lifts every black. None when nothing changes.
    pub fn patch(nal: &[u8]) -> Option<Vec<u8>> {
        let rbsp = unescape(nal);
        let found = locate(&rbsp)?;
        let mut bits = unpack(&rbsp);
        // drop the trailing closing bit and padding
        while bits.last() == Some(&false) {
            bits.pop();
        }
        bits.pop();
        let mut changed = false;
        // ue(1) is 010 and ue(2) is 011: same length, so lowering the buffer is a bit flip
        if found.dpb.1 == 2 && found.refs.max(1) == 1 {
            bits[found.dpb.0 + 2] = false;
            changed = true;
        }
        if !found.signal_flag.1 {
            let at = found.signal_flag.0;
            bits[at] = true;
            // video_format 5 (unspecified), limited range, colour description present, then BT.709 three times
            let mut add = vec![true, false, true, false, true];
            for _ in 0..3 {
                add.extend([false, false, false, false, false, false, false, true]);
            }
            add.splice(5..5, []);
            for (i, b) in add.into_iter().enumerate() {
                bits.insert(at + 1 + i, b);
            }
            changed = true;
        }
        changed.then(|| escape(&pack(bits)))
    }
}

/// An access unit as the encoder wrote it, with every SPS patched.
fn patch_stream(data: &[u8]) -> Vec<u8> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            starts.push(i);
            i += 3;
        } else {
            i += 1;
        }
    }
    if starts.is_empty() {
        return data.to_vec();
    }
    let mut out = Vec::with_capacity(data.len() + 8);
    out.extend_from_slice(&data[..starts[0]]);
    for (n, &s) in starts.iter().enumerate() {
        let end = starts.get(n + 1).copied().unwrap_or(data.len());
        // a four byte start code leaves one zero at the end of the previous unit
        let mut body_end = end;
        while body_end > s + 3 && data[body_end - 1] == 0 && n + 1 < starts.len() {
            body_end -= 1;
        }
        let nal = &data[s + 3..body_end];
        out.extend_from_slice(&data[s..s + 3]);
        match nal.first() {
            Some(b) if b & 0x1f == 7 => {
                out.extend_from_slice(&sps::patch(nal).unwrap_or_else(|| nal.to_vec()))
            }
            _ => out.extend_from_slice(nal),
        }
        out.extend_from_slice(&data[body_end..end]);
    }
    out
}

const KICK_AFTER: Duration = Duration::from_millis(40);
const RING: usize = 4;

#[derive(Default)]
struct State {
    /// fourcc, width, height of the dmabuf the compositor wants for this frame
    dmabuf: Option<(u32, u32, u32)>,
    done: bool,
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
            Event::LinuxDmabuf {
                format,
                width,
                height,
            } => state.dmabuf = Some((format, width, height)),
            Event::BufferDone => state.done = true,
            Event::Ready { .. } => state.result = Some(true),
            Event::Failed => state.result = Some(false),
            _ => {}
        }
    }
}

delegate_noop!(State: HyprlandToplevelExportManagerV1);
delegate_noop!(State: ignore ZwpLinuxDmabufV1);
delegate_noop!(State: ignore ZwpLinuxBufferParamsV1);
delegate_noop!(State: ignore wl_buffer::WlBuffer);

struct Slot {
    wl: wl_buffer::WlBuffer,
    fd: OwnedFd,
}

fn render_node() -> String {
    std::env::var("LAB_RENDER_NODE").unwrap_or_else(|_| "/dev/dri/renderD128".to_owned())
}

/// Waits for the capture to finish. None on timeout.
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

/// The DRM modifier the VA converter accepts for ARGB input. VA-API on AMD wants a tiled layout, a linear
/// buffer is refused at negotiation, so the buffers are allocated with whatever the plugin lists.
fn va_modifier(fourcc: &str) -> Option<u64> {
    let factory = gst::ElementFactory::find("vapostproc")?;
    for template in factory.static_pad_templates() {
        if template.direction() != gst::PadDirection::Sink {
            continue;
        }
        for s in template.caps().iter() {
            if s.name() != "video/x-raw"
                || s.get::<String>("format").ok().as_deref() != Some("DMA_DRM")
            {
                continue;
            }
            let list = s.value("drm-format").ok()?;
            let items: Vec<String> = if let Ok(l) = list.get::<gst::List>() {
                l.iter().filter_map(|v| v.get::<String>().ok()).collect()
            } else {
                list.get::<String>().ok().into_iter().collect()
            };
            for item in items {
                if let Some(m) = item.strip_prefix(&format!("{fourcc}:0x")) {
                    return u64::from_str_radix(m, 16).ok();
                }
            }
        }
    }
    None
}

fn run(address: u32, qp: u32) -> Result<u8, Box<dyn std::error::Error>> {
    gst::init()?;
    let conn = Connection::connect_to_env()?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn)?;
    let qh = queue.handle();
    let manager: HyprlandToplevelExportManagerV1 = globals.bind(&qh, 1..=2, ())?;
    let Ok(dmabuf): Result<ZwpLinuxDmabufV1, _> = globals.bind(&qh, 3..=4, ()) else {
        eprintln!("lab-stream: the compositor has no linux-dmabuf");
        return Ok(4);
    };
    let mut state = State::default();

    // learn the size and format from a first request, then allocate the buffers for it
    let probe = manager.capture_toplevel(0, address, &qh, ());
    let mut waited = 0;
    while !state.done && waited < 30 {
        queue.roundtrip(&mut state)?;
        waited += 1;
    }
    probe.destroy();
    let Some((fourcc, w, h)) = state.dmabuf else {
        eprintln!("lab-stream: the compositor offers no dmabuf for this window");
        return Ok(4);
    };

    let Some(want) = va_modifier("AR24") else {
        eprintln!("lab-stream: the VA converter takes no ARGB dmabuf here");
        return Ok(4);
    };
    let node = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(render_node())?;
    let gbm = gbm::Device::new(node)?;
    let mut slots = Vec::new();
    let mut stride = 0u32;
    for _ in 0..RING {
        let bo = gbm.create_buffer_object_with_modifiers2::<()>(
            w,
            h,
            gbm::Format::Argb8888,
            [gbm::Modifier::from(want)].into_iter(),
            gbm::BufferObjectFlags::RENDERING,
        )?;
        stride = bo.stride_for_plane(0);
        let offset = bo.offset(0);
        let fd = bo.fd_for_plane(0)?;
        let modifier: u64 = bo.modifier().into();
        let params = dmabuf.create_params(&qh, ());
        params.add(
            fd.as_fd(),
            0,
            offset,
            stride,
            (modifier >> 32) as u32,
            modifier as u32,
        );
        let wl = params.create_immed(w as i32, h as i32, fourcc, Flags::empty(), &qh, ());
        slots.push(Slot { wl, fd });
        // the buffer object may go: the fd keeps the memory alive
    }

    let caps = gst::Caps::builder("video/x-raw")
        .features(["memory:DMABuf"])
        .field("format", "DMA_DRM")
        .field("drm-format", format!("AR24:0x{want:016x}"))
        .field("width", w as i32)
        .field("height", h as i32)
        .field("framerate", gst::Fraction::new(0, 1))
        .build();
    // constrained baseline cannot reorder frames, so the decoder at the other end may show each one at once
    // instead of waiting for the next; it costs some compression, which a LAN does not mind
    let profile =
        std::env::var("LAB_STREAM_PROFILE").unwrap_or_else(|_| "constrained-baseline".to_owned());
    let encoder = std::env::var("LAB_STREAM_ENCODER").unwrap_or_else(|_| "vah264enc".to_owned());
    let profile_caps = if profile == "any" {
        String::new()
    } else {
        format!(",profile={profile}")
    };
    let pipeline = gst::parse::launch(&format!(
        "appsrc name=src ! vapostproc ! video/x-raw(memory:VAMemory),format=NV12,colorimetry=bt709 ! \
         {encoder} rate-control=cqp qpi={qp} qpp={qp} b-frames=0 ref-frames=1 key-int-max=120 target-usage=7 ! \
         video/x-h264,stream-format=byte-stream,alignment=au{profile_caps} ! appsink name=sink sync=false max-buffers=2 drop=true"
    ))?
    .downcast::<gst::Pipeline>()
    .map_err(|_| "not a pipeline")?;
    let appsrc = pipeline
        .by_name("src")
        .ok_or("no appsrc")?
        .downcast::<gst_app::AppSrc>()
        .map_err(|_| "appsrc")?;
    appsrc.set_caps(Some(&caps));
    appsrc.set_format(gst::Format::Time);
    appsrc.set_is_live(true);
    appsrc.set_do_timestamp(true);
    appsrc.set_block(false);
    appsrc.set_max_bytes(0);
    let appsink = pipeline
        .by_name("sink")
        .ok_or("no appsink")?
        .downcast::<gst_app::AppSink>()
        .map_err(|_| "appsink")?;
    // SAFETY: fd 1 is stdout and nothing else in this process writes to it.
    let out = Arc::new(Mutex::new(unsafe { File::from_raw_fd(1) }));
    let closed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let (out2, closed2) = (out.clone(), closed.clone());
    // LAB_STREAM_STATS=1 prints how long a frame takes from "window rendered" to "encoded bytes out"
    let stats = std::env::var_os("LAB_STREAM_STATS").is_some();
    let pushed: Arc<Mutex<std::collections::VecDeque<std::time::Instant>>> = Arc::default();
    let (pushed2, mut samples) = (pushed.clone(), Vec::<f64>::new());
    appsink.set_callbacks(
        gst_app::AppSinkCallbacks::builder()
            .new_sample(move |sink| {
                let sample = sink.pull_sample().map_err(|_| gst::FlowError::Eos)?;
                let buffer = sample.buffer().ok_or(gst::FlowError::Error)?;
                let map = buffer.map_readable().map_err(|_| gst::FlowError::Error)?;
                if stats {
                    if let Some(t) = pushed2.lock().unwrap().pop_front() {
                        samples.push(t.elapsed().as_secs_f64() * 1000.0);
                        if samples.len() >= 120 {
                            let avg = samples.iter().sum::<f64>() / samples.len() as f64;
                            let max = samples.iter().cloned().fold(0.0, f64::max);
                            eprintln!("lab-stream: render to encoded bytes avg {avg:.1} ms, max {max:.1} ms over {} frames", samples.len());
                            samples.clear();
                        }
                    }
                }
                if out2.lock().unwrap().write_all(&patch_stream(map.as_slice())).is_err() {
                    closed2.store(true, std::sync::atomic::Ordering::SeqCst);
                    return Err(gst::FlowError::Eos);
                }
                Ok(gst::FlowSuccess::Ok)
            })
            .build(),
    );
    pipeline.set_state(gst::State::Playing)?;
    // say why the pipeline stops, a silent encoder is hard to debug
    if let Some(bus) = pipeline.bus() {
        std::thread::spawn(move || {
            for msg in bus.iter_timed(gst::ClockTime::NONE) {
                if let gst::MessageView::Error(e) = msg.view() {
                    eprintln!("lab-stream: {} ({:?})", e.error(), e.debug());
                }
            }
        });
    }

    let allocator = gst_alloc::DmaBufAllocator::new();
    // the allocation size, from the descriptor itself because the tiled layout pads the height
    let size = {
        // SAFETY: lseek on a descriptor this process owns.
        let end = unsafe { libc::lseek(slots[0].fd.as_raw_fd(), 0, libc::SEEK_END) };
        if end > 0 {
            end as usize
        } else {
            (stride * h) as usize
        }
    };
    let push = |slot: &Slot| -> Result<(), Box<dyn std::error::Error>> {
        pushed.lock().unwrap().push_back(std::time::Instant::now());
        let fd = slot.fd.try_clone()?;
        // SAFETY: the allocator takes ownership of the duplicated descriptor.
        let memory = unsafe { allocator.alloc_dmabuf(fd, size)? };
        let mut buffer = gst::Buffer::new();
        {
            let b = buffer.get_mut().ok_or("buffer not writable")?;
            b.append_memory(memory);
            gst_video::VideoMeta::add_full(
                b,
                gst_video::VideoFrameFlags::empty(),
                gst_video::VideoFormat::DmaDrm,
                w,
                h,
                &[0],
                &[stride as i32],
            )?;
        }
        appsrc
            .push_buffer(buffer)
            .map(|_| ())
            .map_err(|e| format!("{e:?}").into())
    };

    let (mut cur, mut need_kick, mut last) = (0usize, false, 0usize);
    loop {
        if closed.load(std::sync::atomic::Ordering::SeqCst) {
            let _ = pipeline.set_state(gst::State::Null);
            return Ok(0);
        }
        let frame = manager.capture_toplevel(0, address, &qh, ());
        state.dmabuf = None;
        state.done = false;
        state.result = None;
        let mut waited = 0;
        while !state.done && waited < 20 {
            queue.roundtrip(&mut state)?;
            waited += 1;
        }
        match state.dmabuf {
            Some((_, nw, nh)) if (nw, nh) != (w, h) => {
                frame.destroy();
                let _ = pipeline.set_state(gst::State::Null);
                return Ok(3);
            }
            None => {
                frame.destroy();
                std::thread::sleep(Duration::from_millis(200));
                continue;
            }
            _ => {}
        }
        frame.copy(&slots[cur].wl, 1);
        let outcome = loop {
            let wait = if need_kick { Some(KICK_AFTER) } else { None };
            match wait_result(
                &mut state,
                &mut queue,
                wait.or(Some(Duration::from_secs(2))),
            )? {
                None if need_kick => {
                    need_kick = false;
                    push(&slots[last])?;
                }
                None => break None,
                done => break done,
            }
        };
        frame.destroy();
        if outcome == Some(true) {
            push(&slots[cur])?;
            need_kick = true;
            last = cur;
            cur = (cur + 1) % RING;
        } else {
            std::thread::sleep(Duration::from_millis(200));
        }
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(address) = args
        .first()
        .and_then(|s| u64::from_str_radix(s.trim_start_matches("0x"), 16).ok())
        .map(|a| (a & 0xffff_ffff) as u32)
    else {
        eprintln!("usage: lab-stream ADDRESS");
        return ExitCode::from(64);
    };
    let qp = std::env::var("LAB_PEER_QP")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(23);
    match run(address, qp) {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("lab-stream: {e}");
            ExitCode::from(4)
        }
    }
}
