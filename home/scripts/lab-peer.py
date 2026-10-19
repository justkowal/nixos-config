#!/usr/bin/env python3
"""lab-peer: lets your other machines see and control this machine's windows.

Listens on this machine's tailnet address only. A request is served only when Tailscale says the
caller is another device of the same user, so there is no token to share.

  HTTP :8766   GET /windows, GET /window/ADDR/info, GET /window/ADDR/related,
               GET /window/ADDR/video (hardware encoded H.264 of that window alone),
               POST /window/ADDR/(focus|close), POST /run {"app": "firefox.desktop"}
  TCP  :8767   input channel: first line {"window": ADDR}, then one JSON event per line:
               {"m":[nx,ny]} {"b":[code,1|0]} {"a":[dx,dy]} {"k":[code,1|0]} {"focus":1}
               with nx,ny in 0..1 over the window. The server answers {"state":"ok"|"hidden"|"gone"}.

Video: lab-capture takes frames from the window's own surface (Hyprland toplevel export), so other
windows, workspaces and the layout around it never show. ffmpeg uploads them to the GPU and
encodes with VA-API. Input: lab-inject replays events through the wlroots virtual input protocols.
"""

import json
import shutil
import os
import re
import select
import socket
import socketserver
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TAILSCALE = os.environ.get("TAILSCALE", "tailscale")
HTTP_PORT = int(os.environ.get("LAB_PEER_PORT", "8766"))
INPUT_PORT = HTTP_PORT + 1
QP = int(os.environ.get("LAB_PEER_QP", "23"))
ADDR_RE = re.compile(r"0x[0-9a-f]{1,16}")
allowed = {}
lock = threading.Lock()
ME = None


def run(cmd, env=None, timeout=10):
    return subprocess.run(cmd, capture_output=True, timeout=timeout, env=env, check=False)


def stage_pid():
    """pid of the headless stage compositor, which runs without a login (see home/lab/peek.nix)."""
    out = run(["systemctl", "--user", "show", "lab-stage-hypr", "-p", "MainPID", "--value"], dict(os.environ))
    return out.stdout.decode().strip()


_session = {"at": 0.0, "env": None}


def session_env():
    """Cached for a second, every request asks for it several times."""
    if _session["env"] is None or time.time() - _session["at"] > 1.0:
        _session["env"], _session["at"] = find_session(), time.time()
    return dict(_session["env"])


def find_session():
    """hyprctl needs the session variables, a systemd user service may not have them. A live session wins,
    the headless stage answers when nobody is logged in."""
    env = dict(os.environ)
    rt = Path(env.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    env["XDG_RUNTIME_DIR"] = str(rt)
    try:
        found = json.loads(run(["hyprctl", "instances", "-j"], env).stdout)
    except ValueError:
        found = []
    stage = stage_pid()
    found.sort(key=lambda i: (str(i.get("pid")) == stage, -int(i.get("time", 0))))
    if found:
        # nobody sits at the stage, so it may switch workspaces to show a window, a live session may not
        env["LAB_STAGE"] = "1" if str(found[0].get("pid")) == stage else ""
        env["HYPRLAND_INSTANCE_SIGNATURE"] = found[0]["instance"]
        env["WAYLAND_DISPLAY"] = found[0]["wl_socket"]
        return env
    hypr = sorted((rt / "hypr").glob("*/.socket.sock"), key=lambda p: p.stat().st_mtime, reverse=True)
    if hypr:
        env["HYPRLAND_INSTANCE_SIGNATURE"] = hypr[0].parent.name
    if "WAYLAND_DISPLAY" not in env:
        socks = sorted(rt.glob("wayland-[0-9]"))
        if socks:
            env["WAYLAND_DISPLAY"] = socks[0].name
    return env


def reveal(addr):
    """On the stage a window that is not on the visible workspace renders nothing, so bring its workspace up."""
    g = window_info(addr)
    if g and not g["visible"] and session_env().get("LAB_STAGE"):
        run(["hyprctl", "dispatch", "workspace", str(g["workspace"])], session_env())


def hypr_json(what):
    out = run(["hyprctl", "-j", what], session_env())
    try:
        return json.loads(out.stdout)
    except ValueError:
        return []


def my_user_id():
    return json.loads(run([TAILSCALE, "status", "--json"]).stdout)["Self"]["UserID"]


def is_my_device(ip):
    """True when Tailscale says `ip` belongs to another untagged device of this user."""
    with lock:
        if ip in allowed:
            return allowed[ip]
    try:
        node = json.loads(run([TAILSCALE, "whois", "--json", ip]).stdout)["Node"]
        ok = node.get("User") == ME and not node.get("Tags")
    except (ValueError, KeyError):
        ok = False
    with lock:
        allowed[ip] = ok
    return ok


def visible_workspaces():
    ids = set()
    for m in hypr_json("monitors"):
        ids.add(m["activeWorkspace"]["id"])
        if m.get("specialWorkspace", {}).get("id"):
            ids.add(m["specialWorkspace"]["id"])
    return ids


def info_of(c, visible):
    return {"addr": c["address"], "stable": c.get("stableId", ""), "pid": c.get("pid", 0), "x": c["at"][0], "y": c["at"][1],
            "w": c["size"][0], "h": c["size"][1], "title": c["title"], "class": c.get("class", ""),
            "workspace": c["workspace"]["id"], "floating": c.get("floating", False),
            "visible": c["workspace"]["id"] in visible}


def window_info(addr):
    visible = visible_workspaces()
    for c in hypr_json("clients"):
        if c["address"] == addr and c.get("mapped"):
            return dict(info_of(c, visible), portal=addr in portals)
    return None


def windows():
    visible = visible_workspaces()
    return [dict(info_of(c, visible), title=c["title"][:120], focused=c.get("focusHistoryID") == 0)
            for c in hypr_json("clients") if c.get("mapped") and not c.get("hidden") and c.get("title")]


# ── audio ────────────────────────────────────────────────────────────────────
# Every viewer gets its own null sink. The audio of the window's process (and its children, which is
# where browsers and games play from) is moved onto it, encoded as low delay Opus and streamed. When the
# viewer leaves, the streams go back to the default sink and the null sink is removed.

SINK_PREFIX = "lab_peek_"


def pactl(*args):
    return run(["pactl", *args], dict(os.environ), timeout=5)


def ancestors(pid, depth=8):
    out = []
    for _ in range(depth):
        try:
            pid = int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
        if pid <= 1:
            break
        out.append(pid)
    return out


ROOT_STOP = {"systemd", "Hyprland", ".Hyprland-wrapped", "labwc", "init"}


def app_root(pid):
    """The topmost process of the tree a window belongs to, below the session itself. A launcher's own window
    often belongs to a helper (Steam's is a web helper) and its games to another branch, the root is shared."""
    for _ in range(40):
        try:
            stat = Path(f"/proc/{pid}/stat").read_text()
            parent = int(stat.rsplit(")", 1)[1].split()[1])
            comm = Path(f"/proc/{parent}/comm").read_text().strip()
        except (OSError, ValueError, IndexError):
            return pid
        if parent <= 1 or comm in ROOT_STOP:
            return pid
        pid = parent
    return pid


def same_app(stream_pid, window_pid):
    return stream_pid == window_pid or window_pid in ancestors(stream_pid) or stream_pid in ancestors(window_pid)


def other_peek_sinks():
    """Indexes of null sinks of other viewers, their streams stay where they are."""
    out = set()
    for line in pactl("list", "short", "sinks").stdout.decode().splitlines():
        cols = line.split("\t")
        if len(cols) > 1 and cols[1].startswith(SINK_PREFIX):
            out.add(int(cols[0]))
    return out


def sink_inputs():
    try:
        return json.loads(pactl("-f", "json", "list", "sink-inputs").stdout)
    except ValueError:
        return []


def default_sink_name():
    return pactl("get-default-sink").stdout.decode().strip()


def recover_audio():
    """Streams stranded on a null sink of a peer that died go back to the default sink."""
    mods = pactl("list", "short", "modules").stdout.decode().splitlines()
    ours = [m.split("\t") for m in mods if SINK_PREFIX in m]
    if not ours:
        return
    default = default_sink_name()
    names = {m[2].split("sink_name=")[1].split()[0] for m in ours if "sink_name=" in m[2]}
    sinks = {s.split("\t")[0]: s.split("\t")[1] for s in pactl("list", "short", "sinks").stdout.decode().splitlines() if "\t" in s}
    for si in sink_inputs():
        if sinks.get(str(si.get("sink"))) in names and default:
            pactl("move-sink-input", str(si["index"]), default)
    for m in ours:
        pactl("unload-module", m[0])


class AudioPortal:
    def __init__(self, addr):
        self.addr = addr
        self.name = f"{SINK_PREFIX}{addr[2:10]}"
        self.module = None
        self.moved = set()
        self.stop = threading.Event()

    def start(self):
        out = pactl("load-module", "module-null-sink", f"sink_name={self.name}", "rate=48000", "channels=2",
                    f"sink_properties=device.description=Peek-{self.name}")
        if out.returncode != 0:
            return False
        self.module = out.stdout.decode().strip()
        threading.Thread(target=self.follow, daemon=True).start()
        return True

    def follow(self):
        while not self.stop.is_set():
            g = window_info(self.addr)
            if g is not None:
                for si in sink_inputs():
                    props = si.get("properties", {})
                    try:
                        pid = int(props.get("application.process.id", 0))
                    except ValueError:
                        pid = 0
                    if pid and si["index"] not in self.moved and same_app(pid, g["pid"]) and si["sink"] not in other_peek_sinks():
                        if pactl("move-sink-input", str(si["index"]), self.name).returncode == 0:
                            self.moved.add(si["index"])
            self.stop.wait(0.4)

    def close(self):
        self.stop.set()
        default = default_sink_name()
        for si in sink_inputs():
            if si["index"] in self.moved and default:
                pactl("move-sink-input", str(si["index"]), default)
        if self.module:
            pactl("unload-module", self.module)


def audio_command(sink):
    # the pulse input reads in small fragments, the encoder emits 10 ms frames and ogg pages follow at once
    return ["ffmpeg", "-nostdin", "-loglevel", "error", "-fflags", "nobuffer", "-flags", "low_delay",
            "-f", "pulse", "-fragment_size", "1920", "-i", f"{sink}.monitor",
            "-c:a", "libopus", "-application", "lowdelay", "-frame_duration", "10", "-b:a", "96k",
            "-f", "ogg", "-page_duration", "10000", "-flush_packets", "1", "pipe:1"]


def related(addr):
    """Dialogs and popups are windows of the same process. Windows of processes it started, which is how a
    launcher such as Lutris or Steam shows its games, are "spawned"."""
    me = window_info(addr)
    if me is None:
        return []
    root = app_root(me["pid"])
    out = []
    for w in windows():
        if w["addr"] == addr:
            continue
        if w["pid"] == me["pid"]:
            out.append(dict(w, kind="dialog"))
        elif app_root(w["pid"]) == root:
            out.append(dict(w, kind="spawned"))
    return out


APP_ID_RE = re.compile(r"[A-Za-z0-9._-]+\.desktop")


def find_app(app_id):
    """The desktop entry file for an app id, only from the installed application folders."""
    if not APP_ID_RE.fullmatch(app_id):
        return None
    user = os.environ.get("USER", "")
    # the order a session itself uses: flatpak exports come before the nix profiles, so the Lutris that
    # has your games is the one that starts, not a second copy with an empty library
    for d in (Path.home() / ".local/share/applications", Path.home() / ".local/share/flatpak/exports/share/applications",
              Path("/var/lib/flatpak/exports/share/applications"), Path(f"/etc/profiles/per-user/{user}/share/applications"),
              Path("/run/current-system/sw/share/applications"), Path.home() / ".nix-profile/share/applications"):
        p = d / app_id
        if p.is_file():
            return p
    return None


def layout_box():
    """Bounding box of all outputs in logical pixels, the space the virtual pointer maps onto."""
    mons = [m for m in hypr_json("monitors") if not m.get("disabled")]
    if not mons:
        return 0, 0, 1920, 1080
    boxes = [(m["x"], m["y"], m["x"] + int(m["width"] / m["scale"]), m["y"] + int(m["height"] / m["scale"])) for m in mons]
    x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
    return x0, y0, max(b[2] for b in boxes) - x0, max(b[3] for b in boxes) - y0


# ── input ────────────────────────────────────────────────────────────────────

# ── portal mode ──────────────────────────────────────────────────────────────
# A window that is being used from another machine moves to a headless output here, so it is not drawn on
# the physical screen twice. It still renders there (an output counts as visible), still takes remote input,
# and a placeholder stays behind. Everything is remembered so that it can always be put back.

PORTAL_OUT = "LAB-PORTAL"
STATE_FILE = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "lab-portal.json"
portals = {}
portal_lock = threading.Lock()


def save_portals():
    try:
        STATE_FILE.write_text(json.dumps(portals))
    except OSError:
        pass


def cursor_pos():
    out = run(["hyprctl", "cursorpos"], session_env()).stdout.decode().strip().split(",")
    try:
        return int(out[0]), int(out[1])
    except (ValueError, IndexError):
        return None


def portal_monitor():
    return next((m for m in hypr_json("monitors") if m["name"] == PORTAL_OUT), None)


def ensure_output(w, h):
    """The headless output sits to the right of the real ones, where the mouse cannot wander in by accident."""
    env = session_env()
    mons = hypr_json("monitors")
    if not any(m["name"] == PORTAL_OUT for m in mons):
        run(["hyprctl", "output", "create", "headless", PORTAL_OUT], env)
    others = [m for m in hypr_json("monitors") if m["name"] != PORTAL_OUT]
    x = max((m["x"] + int(m["width"] / m["scale"]) for m in others), default=0)
    run(["hyprctl", "keyword", "monitor", f"{PORTAL_OUT},{w}x{h}@60,{x}x0,1"], env)
    for _ in range(20):
        mon = portal_monitor()
        if mon and mon["activeWorkspace"]["id"] > 0:
            return mon
        time.sleep(0.05)
    return None


def portal_window(addr, w, h, by):
    w, h = max(320, int(w) & ~1), max(200, int(h) & ~1)
    with portal_lock:
        if addr in portals:
            return resize_portal(addr, w, h)
        info = window_info(addr)
        if info is None:
            return False
        mon = ensure_output(w, h)
        if mon is None:
            return False
        env = session_env()
        portals[addr] = {"orig": info, "cursor": cursor_pos(), "by": by, "w": w, "h": h}
        save_portals()
        ws = mon["activeWorkspace"]["id"]
        run(["hyprctl", "dispatch", "movetoworkspacesilent", f"{ws},address:{addr}"], env)
        if info["floating"]:
            run(["hyprctl", "dispatch", "resizewindowpixel", f"exact {w} {h},address:{addr}"], env)
            run(["hyprctl", "dispatch", "movewindowpixel", f"exact {mon['x']} {mon['y']},address:{addr}"], env)
        # the placeholder takes the place the window left, floating where it floated
        # nobody looks at the stage, so no placeholder there
        if not env.get("LAB_STAGE"):
            rule = "float;size {w} {h};move {x} {y};".format(**{"w": info["w"], "h": info["h"], "x": info["x"], "y": info["y"]}) if info["floating"] else ""
            run(["hyprctl", "dispatch", "exec", f"[{rule}workspace {info['workspace']} silent] {shutil.which('lab-peek') or 'lab-peek'} --placeholder {addr} {by}"], env)
        return True


def resize_portal(addr, w, h):
    """Called with the lock held. The output follows the viewer, so the stream is always native size."""
    p = portals.get(addr)
    if p is None or (p["w"], p["h"]) == (w, h):
        return p is not None
    p["w"], p["h"] = w, h
    mon = ensure_output(w, h)
    if mon and window_info(addr) and window_info(addr)["floating"]:
        env = session_env()
        run(["hyprctl", "dispatch", "resizewindowpixel", f"exact {w} {h},address:{addr}"], env)
        run(["hyprctl", "dispatch", "movewindowpixel", f"exact {mon['x']} {mon['y']},address:{addr}"], env)
    save_portals()
    return True


def unportal_window(addr):
    with portal_lock:
        p = portals.pop(addr, None)
        if p is None:
            return False
        save_portals()
        env = session_env()
        o = p["orig"]
        if window_info(addr):
            run(["hyprctl", "dispatch", "movetoworkspacesilent", f"{o['workspace']},address:{addr}"], env)
            if o["floating"]:
                run(["hyprctl", "dispatch", "resizewindowpixel", f"exact {o['w']} {o['h']},address:{addr}"], env)
                run(["hyprctl", "dispatch", "movewindowpixel", f"exact {o['x']} {o['y']},address:{addr}"], env)
        # the placeholder has done its job
        for c in hypr_json("clients"):
            if c.get("class") == "lab.justkowal.Portal" and c["workspace"]["id"] == o["workspace"] and c["title"].endswith(addr):
                run(["hyprctl", "dispatch", "closewindow", f"address:{c['address']}"], env)
        if not portals:
            run(["hyprctl", "output", "remove", PORTAL_OUT], env)
        # a remote session may have left the cursor on the invisible output
        if p.get("cursor"):
            run(["hyprctl", "dispatch", "movecursor", f"{p['cursor'][0]} {p['cursor'][1]}"], env)
        run(["hyprctl", "dispatch", "focuswindow", f"address:{addr}"], env)
        return True


def recover_portals():
    """After a crash or restart, put back whatever is still on the headless output."""
    try:
        saved = json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        saved = {}
    with portal_lock:
        portals.update(saved)
    for addr in list(saved):
        unportal_window(addr)
    if portal_monitor() and not portals:
        run(["hyprctl", "output", "remove", PORTAL_OUT], session_env())


class Injector:
    """One lab-inject child shared by every input connection."""

    def __init__(self):
        self.proc = None
        self.display = None
        self.lock = threading.Lock()

    def send(self, obj):
        line = (json.dumps(obj) + "\n").encode()
        with self.lock:
            for _ in range(2):
                env = session_env()
                # a live session may have appeared since, the helper has to follow it
                if self.proc is not None and self.display != env.get("WAYLAND_DISPLAY"):
                    self.proc.kill()
                    self.proc.wait()
                if self.proc is None or self.proc.poll() is not None:
                    self.display = env.get("WAYLAND_DISPLAY")
                    self.proc = subprocess.Popen(["lab-inject"], stdin=subprocess.PIPE, env=env)
                try:
                    self.proc.stdin.write(line)
                    self.proc.stdin.flush()
                    return
                except (BrokenPipeError, OSError):
                    self.proc = None


injector = Injector()


class Tracker:
    """Keeps the window's place fresh off the event path, hyprctl is too slow to call per mouse move."""

    def __init__(self, addr):
        self.addr, self.info, self.box, self.stop = addr, None, layout_box(), False
        self.refresh()
        threading.Thread(target=self.loop, daemon=True).start()

    def refresh(self):
        info = window_info(self.addr)
        if info is not None:
            self.box = layout_box()
        self.info = info

    def loop(self):
        while not self.stop:
            time.sleep(0.2)
            self.refresh()


conns = {}


def release_later(addr):
    """A viewer that disappears must not strand its window on the invisible output."""
    def check():
        if conns.get(addr, 0) == 0 and addr in portals:
            unportal_window(addr)

    threading.Timer(8.0, check).start()


def open_pad(spec):
    """A virtual gamepad that looks exactly like the physical one, so SDL and Steam Input pick the same mapping."""
    from evdev import AbsInfo, UInput

    name, vendor, product, version, caps = spec
    events = {}
    for etype, codes in caps.items():
        events[int(etype)] = [(c[0], AbsInfo(*c[1])) if isinstance(c, list) else c for c in codes]
    return UInput(events, name=name[:60], vendor=vendor, product=product, version=version)


class InputHandler(socketserver.StreamRequestHandler):
    def say(self, state):
        try:
            self.wfile.write((json.dumps({"state": state}) + "\n").encode())
            self.wfile.flush()
        except OSError:
            pass

    def handle(self):
        if not is_my_device(self.client_address[0]):
            return
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        try:
            addr = json.loads(self.rfile.readline(512))["window"]
        except (ValueError, KeyError, TypeError):
            return
        if not isinstance(addr, str) or not ADDR_RE.fullmatch(addr):
            return
        conns[addr] = conns.get(addr, 0) + 1
        track = Tracker(addr)
        reveal(addr)
        held_keys, held_buttons, said = set(), set(), None
        pads = {}
        if track.info and track.info["visible"]:
            run(["hyprctl", "dispatch", "focuswindow", f"address:{addr}"], session_env())
        try:
            for raw in self.rfile:
                try:
                    ev = json.loads(raw)
                except ValueError:
                    continue
                g = track.info
                state = "gone" if g is None else ("ok" if g["visible"] else "hidden")
                if state != said:
                    said = state
                    self.say(state)
                if g is None:
                    return
                if "focus" in ev:
                    # an explicit request, this is the one input that switches workspace over there
                    run(["hyprctl", "dispatch", "focuswindow", f"address:{addr}"], session_env())
                    continue
                if state != "ok":
                    # never aim the virtual pointer at a window that is not on screen, it would hit something else
                    continue
                box = track.box
                if "m" in ev:
                    nx, ny = max(0.0, min(1.0, float(ev["m"][0]))), max(0.0, min(1.0, float(ev["m"][1])))
                    injector.send({"m": [int(g["x"] + nx * g["w"] - box[0]), int(g["y"] + ny * g["h"] - box[1]), box[2], box[3]]})
                elif "gpo" in ev:
                    try:
                        n, *spec = ev["gpo"]
                        if n not in pads:
                            pads[n] = open_pad(spec)
                    except (ImportError, OSError, ValueError, TypeError):
                        pass
                elif "gp" in ev:
                    n, etype, code, value = ev["gp"]
                    if n in pads:
                        pads[n].write(int(etype), int(code), int(value))
                elif "r" in ev:
                    # game mode, relative motion only, the remote pointer is not warped
                    injector.send({"r": [float(ev["r"][0]), float(ev["r"][1])]})
                elif "b" in ev:
                    code, down = int(ev["b"][0]), int(ev["b"][1])
                    (held_buttons.add if down else held_buttons.discard)(code)
                    injector.send({"b": [code, down]})
                elif "a" in ev:
                    injector.send({"a": [float(ev["a"][0]), float(ev["a"][1])]})
                elif "k" in ev:
                    code, down = int(ev["k"][0]), int(ev["k"][1])
                    (held_keys.add if down else held_keys.discard)(code)
                    injector.send({"k": [code, down]})
        finally:
            track.stop = True
            conns[addr] = max(0, conns.get(addr, 1) - 1)
            if conns[addr] == 0:
                release_later(addr)
            for pad in pads.values():
                pad.close()
            # a dropped connection must not leave a key or button held down over there
            for code in held_buttons:
                injector.send({"b": [code, 0]})
            for code in held_keys:
                injector.send({"k": [code, 0]})


# ── video ────────────────────────────────────────────────────────────────────

def render_node():
    nodes = sorted(Path("/dev/dri").glob("renderD*"))
    return str(nodes[0]) if nodes else None


def encoder_cmd(w, h, pixfmt, hardware):
    node = render_node()
    base = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-fflags", "nobuffer", "-flags", "low_delay",
            "-use_wallclock_as_timestamps", "1", "-f", "rawvideo", "-pixel_format", pixfmt, "-video_size", f"{w}x{h}", "-i", "-"]
    if hardware and node:
        # no B-frames and a one deep queue keep the delay to a frame. Constant quality, because a target
        # bitrate starves a mostly static screen and turns text into mush; motion simply costs more bits.
        return base + ["-vaapi_device", node, "-vf", "hwupload,scale_vaapi=w=trunc(iw/2)*2:h=trunc(ih/2)*2:format=nv12:out_color_matrix=bt709:out_range=tv",
                       "-c:v", "h264_vaapi", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv", "-bf", "0", "-g", "120", "-async_depth", "1", "-rc_mode", "CQP", "-qp", str(QP),
                       "-fps_mode", "passthrough", "-f", "h264", "pipe:1"]
    return base + ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2:out_color_matrix=bt709:out_range=tv,format=yuv420p", "-c:v", "libx264", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv", "-preset", "ultrafast",
                   "-tune", "zerolatency", "-bf", "0", "-g", "120", "-crf", str(QP), "-fps_mode", "passthrough", "-f", "h264", "pipe:1"]


def debug_log():
    """LAB_PEER_DEBUG=file keeps the stderr of the capture and encoder processes, silence otherwise."""
    path = os.environ.get("LAB_PEER_DEBUG")
    return open(path, "ab") if path else subprocess.DEVNULL


def start_pipeline(addr, hardware):
    """lab-capture into ffmpeg, the pixels never pass through this process. None when the window is gone."""
    hr, hw = os.pipe()
    cap = subprocess.Popen(["lab-capture", addr, "--header-fd", str(hw)], stdout=subprocess.PIPE, stderr=debug_log(),
                           env=session_env(), pass_fds=(hw,))
    os.close(hw)
    line = ""
    if select.select([hr], [], [], 4.0)[0]:
        line = os.read(hr, 128).decode().strip()
    os.close(hr)
    if not line:
        cap.kill()
        cap.wait()
        return None
    w, h, _ = line.split()
    # the alpha byte is padding for a window, and the GPU colour conversion would blend a stray value into purple
    pixfmt = "bgr0"
    enc = subprocess.Popen(encoder_cmd(w, h, pixfmt, hardware), stdin=cap.stdout, stdout=subprocess.PIPE, stderr=debug_log())
    cap.stdout.close()
    return cap, enc


def start_zero_copy(addr):
    """lab-stream: the window goes from GPU buffers into the GPU encoder, nothing is read back."""
    env = session_env()
    env.setdefault("LIBVA_DRIVERS_PATH", "/run/opengl-driver/lib/dri")
    enc = subprocess.Popen(["lab-stream", addr], stdout=subprocess.PIPE, stderr=debug_log(), env=env)
    return None, enc


def nudge_until(flag):
    """An idle window never completes a capture, so ask the compositor to render once until the first frame is out."""
    for _ in range(12):
        if flag.is_set():
            return
        run(["hyprctl", "dispatch", "dpms", "on"], session_env())
        flag.wait(0.25)


def stop_pipeline(pipe):
    procs = [p for p in pipe if p is not None]
    for p in procs:
        p.kill()
    for p in procs:
        p.wait()


class Handler(BaseHTTPRequestHandler):
    server_version = "lab-peer"
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def json(self, code, obj):
        self.reply(code, json.dumps(obj).encode())

    def guard(self):
        if is_my_device(self.client_address[0]):
            return True
        self.json(403, {"error": "not one of your devices"})
        return False

    def audio(self, addr):
        if window_info(addr) is None:
            return self.json(404, {"error": "gone"})
        portal = AudioPortal(addr)
        if not portal.start():
            return self.json(503, {"error": "no audio server"})
        self.send_response(200)
        self.send_header("Content-Type", "audio/ogg")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        enc = subprocess.Popen(audio_command(portal.name), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            while enc.poll() is None:
                ready, _, _ = select.select([enc.stdout], [], [], 0.5)
                if ready:
                    chunk = os.read(enc.stdout.fileno(), 4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                elif window_info(addr) is None:
                    break
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            enc.kill()
            enc.wait()
            portal.close()

    def video(self, addr):
        g = window_info(addr)
        if g is None:
            return self.json(404, {"error": "gone"})
        reveal(addr)
        self.send_response(200)
        self.send_header("Content-Type", "video/h264")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        # small frames must leave at once, Nagle would hold them back for the next ACK
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        # zero copy first, then the readback path with a GPU encoder, then a CPU encoder
        mode = "zero" if os.environ.get("LAB_PEER_ZEROCOPY", "1") != "0" else "gpu"
        sent, pipe = 0, None
        try:
            while True:
                if pipe is None:
                    pipe = start_zero_copy(addr) if mode == "zero" else start_pipeline(addr, mode == "gpu")
                    if pipe is None:
                        return
                    started = time.time()
                    first_out = threading.Event()
                    threading.Thread(target=nudge_until, args=(first_out,), daemon=True).start()
                cap, enc = pipe
                ready, _, _ = select.select([enc.stdout], [], [], 0.5)
                if ready:
                    chunk = os.read(enc.stdout.fileno(), 65536)
                    if chunk:
                        self.wfile.write(chunk)
                        sent += len(chunk)
                        first_out.set()
                        continue
                # the encoder is done: the window changed size (restart), went away, or the GPU path failed
                code = cap.poll() if cap else None
                if enc.poll() is not None or code is not None:
                    # the exit code of the capturing process: 3 means the window changed size, 4 means this path is unavailable
                    cap_code = (cap or enc).wait() if (cap or enc).poll() is None else (cap or enc).poll()
                    stop_pipeline(pipe)
                    pipe = None
                    if sent == 0 and time.time() - started < 4 and cap_code != 3:
                        mode = {"zero": "gpu", "gpu": "cpu"}.get(mode)
                        if mode:
                            continue
                    if cap_code == 3:
                        continue
                    return
                if window_info(addr) is None:
                    return
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            if pipe:
                stop_pipeline(pipe)

    def do_GET(self):
        if not self.guard():
            return
        if self.path == "/hello":
            return self.json(200, {"host": socket.gethostname()})
        if self.path == "/windows":
            return self.json(200, windows())
        m = re.fullmatch(r"/window/(0x[0-9a-f]{1,16})/(video|audio|info|related)", self.path)
        if m:
            addr, what = m.groups()
            if what == "video":
                return self.video(addr)
            if what == "audio":
                return self.audio(addr)
            if what == "related":
                return self.json(200, related(addr))
            info = window_info(addr)
            return self.json(200, info) if info else self.json(404, {"error": "gone"})
        self.json(404, {"error": "unknown path"})

    def do_POST(self):
        if not self.guard():
            return
        if self.path == "/run":
            # open an installed app in this session, by desktop file name only, never an arbitrary command
            try:
                app = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 512)))["app"]
            except (ValueError, KeyError, TypeError):
                return self.json(400, {"error": "bad body"})
            path = find_app(app) if isinstance(app, str) else None
            if path is None:
                return self.json(404, {"error": "no such app"})
            # Hyprland execs in its own environment, where gio is not on PATH
            out = run(["hyprctl", "dispatch", "exec", f"{shutil.which('gio') or 'gio'} launch '{path}'"], session_env())
            return self.json(200, {"ok": out.returncode == 0})
        m = re.fullmatch(r"/window/(0x[0-9a-f]{1,16})/(portal|unportal)", self.path)
        if m:
            addr, what = m.groups()
            if what == "unportal":
                return self.json(200, {"ok": unportal_window(addr)})
            try:
                b = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 256)))
                ok = portal_window(addr, b["w"], b["h"], str(b.get("by", "another machine"))[:32].replace(" ", "-"))
            except (ValueError, KeyError, TypeError):
                return self.json(400, {"error": "bad body"})
            return self.json(200, {"ok": ok})
        m = re.fullmatch(r"/window/(0x[0-9a-f]{1,16})/(focus|close)", self.path)
        if not m:
            return self.json(404, {"error": "unknown path"})
        addr, action = m.groups()
        run(["hyprctl", "dispatch", "focuswindow" if action == "focus" else "closewindow", f"address:{addr}"], session_env())
        self.json(200, {"ok": True})


class ThreadedTCP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    global ME
    ME = my_user_id()
    recover_portals()
    recover_audio()
    ip = run([TAILSCALE, "ip", "-4"]).stdout.decode().split()[0]
    threading.Thread(target=ThreadedTCP((ip, INPUT_PORT), InputHandler).serve_forever, daemon=True).start()
    http = ThreadingHTTPServer((ip, HTTP_PORT), Handler)
    http.daemon_threads = True
    http.serve_forever()


if __name__ == "__main__":
    main()
