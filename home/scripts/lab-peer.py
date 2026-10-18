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


def session_env():
    """hyprctl needs the session variables, a systemd user service may not have them."""
    env = dict(os.environ)
    rt = Path(env.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    env["XDG_RUNTIME_DIR"] = str(rt)
    hypr = sorted((rt / "hypr").glob("*/.socket.sock"), key=lambda p: p.stat().st_mtime, reverse=True)
    if hypr:
        env["HYPRLAND_INSTANCE_SIGNATURE"] = hypr[0].parent.name
    if "WAYLAND_DISPLAY" not in env:
        socks = sorted(rt.glob("wayland-[0-9]"))
        if socks:
            env["WAYLAND_DISPLAY"] = socks[0].name
    return env


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
            return info_of(c, visible)
    return None


def windows():
    visible = visible_workspaces()
    return [dict(info_of(c, visible), title=c["title"][:120], focused=c.get("focusHistoryID") == 0)
            for c in hypr_json("clients") if c.get("mapped") and not c.get("hidden") and c.get("title")]


def related(addr):
    """Other windows of the same process, which is how dialogs and popups of an app show up."""
    me = window_info(addr)
    if me is None:
        return []
    return [w for w in windows() if w["pid"] == me["pid"] and w["addr"] != addr]


APP_ID_RE = re.compile(r"[A-Za-z0-9._-]+\.desktop")


def find_app(app_id):
    """The desktop entry file for an app id, only from the installed application folders."""
    if not APP_ID_RE.fullmatch(app_id):
        return None
    user = os.environ.get("USER", "")
    for d in (Path.home() / ".local/share/applications", Path(f"/etc/profiles/per-user/{user}/share/applications"),
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

class Injector:
    """One lab-inject child shared by every input connection."""

    def __init__(self):
        self.proc = None
        self.lock = threading.Lock()

    def send(self, obj):
        line = (json.dumps(obj) + "\n").encode()
        with self.lock:
            for _ in range(2):
                if self.proc is None or self.proc.poll() is not None:
                    self.proc = subprocess.Popen(["lab-inject"], stdin=subprocess.PIPE, env=session_env())
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
        track = Tracker(addr)
        held_keys, held_buttons, said = set(), set(), None
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


def nudge_until(flag):
    """An idle window never completes a capture, so ask the compositor to render once until the first frame is out."""
    for _ in range(12):
        if flag.is_set():
            return
        run(["hyprctl", "dispatch", "dpms", "on"], session_env())
        flag.wait(0.25)


def stop_pipeline(pipe):
    for p in pipe:
        p.kill()
    for p in pipe:
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

    def video(self, addr):
        g = window_info(addr)
        if g is None:
            return self.json(404, {"error": "gone"})
        self.send_response(200)
        self.send_header("Content-Type", "video/h264")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        # small frames must leave at once, Nagle would hold them back for the next ACK
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        hardware, sent, pipe = True, 0, None
        try:
            while True:
                if pipe is None:
                    pipe = start_pipeline(addr, hardware)
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
                code = cap.poll()
                if enc.poll() is not None or code is not None:
                    cap_code = cap.wait() if code is None else code
                    stop_pipeline(pipe)
                    pipe = None
                    if hardware and sent == 0 and time.time() - started < 4 and cap_code in (None, 3, -9, -13):
                        hardware = False
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
        m = re.fullmatch(r"/window/(0x[0-9a-f]{1,16})/(video|info|related)", self.path)
        if m:
            addr, what = m.groups()
            if what == "video":
                return self.video(addr)
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
            out = run(["hyprctl", "dispatch", "exec", f"gio launch '{path}'"], session_env())
            return self.json(200, {"ok": out.returncode == 0})
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
    ip = run([TAILSCALE, "ip", "-4"]).stdout.decode().split()[0]
    threading.Thread(target=ThreadedTCP((ip, INPUT_PORT), InputHandler).serve_forever, daemon=True).start()
    http = ThreadingHTTPServer((ip, HTTP_PORT), Handler)
    http.daemon_threads = True
    http.serve_forever()


if __name__ == "__main__":
    main()
