#!/usr/bin/env python3
"""lab-peer: lets your other machines see and control this machine's windows.

Listens on this machine's tailnet address only. A request is served only when Tailscale says the
caller is another device of the same user, so there is no token to share.

  HTTP :8766   GET /windows, GET /window/ADDR/video (hardware encoded H.264, 60 fps),
               GET /window/ADDR.png, POST /window/ADDR/(focus|close)
  TCP  :8767   input channel: first line {"window": ADDR}, then one JSON event per line:
               {"m":[nx,ny]} {"b":[code,1|0]} {"a":[dx,dy]} {"k":[code,1|0]} with nx,ny in 0..1 over the window

Video comes from wf-recorder (wlr-screencopy, DMA-BUF) straight into the GPU's VA-API encoder.
Input goes through lab-inject (wlroots virtual pointer and keyboard).
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
MAX_WIDTH = 1280
QP = int(os.environ.get("LAB_PEER_QP", "23"))
ADDR_RE = re.compile(r"0x[0-9a-f]{1,16}")
allowed = {}
lock = threading.Lock()
ME = None


def run(cmd, env=None, timeout=10):
    return subprocess.run(cmd, capture_output=True, timeout=timeout, env=env, check=False)


def session_env():
    """hyprctl and grim need the session variables, a systemd user service may not have them."""
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
    return {m["activeWorkspace"]["id"] for m in hypr_json("monitors")}


def window_info(addr):
    for c in hypr_json("clients"):
        if c["address"] == addr and c.get("mapped"):
            return {"x": c["at"][0], "y": c["at"][1], "w": c["size"][0], "h": c["size"][1], "title": c["title"],
                    "workspace": c["workspace"]["id"]}
    return None


def layout_box():
    """Bounding box of all outputs in logical pixels, the space the virtual pointer maps onto."""
    mons = [m for m in hypr_json("monitors") if not m.get("disabled")]
    if not mons:
        return 0, 0, 1920, 1080
    boxes = [(m["x"], m["y"], m["x"] + int(m["width"] / m["scale"]), m["y"] + int(m["height"] / m["scale"])) for m in mons]
    x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
    return x0, y0, max(b[2] for b in boxes) - x0, max(b[3] for b in boxes) - y0


def windows():
    visible = visible_workspaces()
    rows = []
    for c in hypr_json("clients"):
        if not c.get("mapped") or c.get("hidden") or not c.get("title"):
            continue
        ws = c["workspace"]["id"]
        rows.append({"addr": c["address"], "title": c["title"][:120], "class": c.get("class", ""), "workspace": ws,
                     "visible": ws in visible, "focused": c.get("focusHistoryID") == 0})
    return rows


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


class InputHandler(socketserver.StreamRequestHandler):
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
        run(["hyprctl", "dispatch", "focuswindow", f"address:{addr}"], session_env())
        held_keys, held_buttons = set(), set()
        geom, geom_at = None, 0.0
        box = layout_box()
        try:
            for raw in self.rfile:
                try:
                    ev = json.loads(raw)
                except ValueError:
                    continue
                if "m" in ev or "a" in ev:
                    if time.time() - geom_at > 0.25:
                        geom, geom_at = window_info(addr), time.time()
                        box = layout_box() if "m" in ev else box
                    if geom is None:
                        return
                if "m" in ev:
                    nx, ny = max(0.0, min(1.0, float(ev["m"][0]))), max(0.0, min(1.0, float(ev["m"][1])))
                    x = geom["x"] + nx * geom["w"] - box[0]
                    y = geom["y"] + ny * geom["h"] - box[1]
                    injector.send({"m": [int(x), int(y), box[2], box[3]]})
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
            # a dropped connection must not leave a key or button held down over there
            for code in held_buttons:
                injector.send({"b": [code, 0]})
            for code in held_keys:
                injector.send({"k": [code, 0]})


# ── video ────────────────────────────────────────────────────────────────────

def render_node():
    nodes = sorted(Path("/dev/dri").glob("renderD*"))
    return str(nodes[0]) if nodes else None


def encoder_cmd(g, hardware=True):
    w, h = max(64, g["w"] & ~1), max(64, g["h"] & ~1)
    region = f"{g['x']},{g['y']} {w}x{h}"
    base = ["wf-recorder", "-g", region, "-m", "h264", "-f", "/dev/stdout"]
    node = render_node()
    if hardware and node:
        # no B-frames and a one deep queue keep the delay to a frame or two. Constant quality, because a
        # target bitrate starves a mostly static screen and turns text into mush; motion simply costs more bits
        return base + ["-c", "h264_vaapi", "-d", node, "-p", "bf=0", "-p", "g=120", "-p", "async_depth=1",
                       "-p", "rc_mode=CQP", "-p", f"qp={QP}"]
    return base + ["-c", "libx264", "-p", "preset=ultrafast", "-p", "tune=zerolatency", "-p", "bf=0", "-p", "crf=23"]


def spawn_encoder(g, hardware):
    return subprocess.Popen(encoder_cmd(g, hardware), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=session_env())


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
        if g["workspace"] not in visible_workspaces():
            return self.json(409, {"error": "not visible"})
        self.send_response(200)
        self.send_header("Content-Type", "video/h264")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        hardware = True
        proc, started, sent, last_check = spawn_encoder(g, hardware), time.time(), 0, time.time()
        try:
            while True:
                ready, _, _ = select.select([proc.stdout], [], [], 0.3)
                if ready:
                    chunk = os.read(proc.stdout.fileno(), 65536)
                    if not chunk:
                        if hardware and sent == 0 and time.time() - started < 3:
                            hardware, proc, started = False, spawn_encoder(g, False), time.time()
                            continue
                        return
                    self.wfile.write(chunk)
                    sent += len(chunk)
                if time.time() - last_check > 0.4:
                    last_check = time.time()
                    now = window_info(addr)
                    if now is None:
                        return
                    if (now["x"], now["y"], now["w"] & ~1, now["h"] & ~1) != (g["x"], g["y"], g["w"] & ~1, g["h"] & ~1):
                        g = now
                        proc.kill()
                        proc.wait()
                        proc = spawn_encoder(g, hardware)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            proc.kill()
            proc.wait()

    def do_GET(self):
        if not self.guard():
            return
        if self.path == "/hello":
            return self.json(200, {"host": socket.gethostname()})
        if self.path == "/windows":
            return self.json(200, windows())
        m = re.fullmatch(r"/window/(0x[0-9a-f]{1,16})/video", self.path)
        if m:
            return self.video(m.group(1))
        m = re.fullmatch(r"/window/(0x[0-9a-f]{1,16})/info", self.path)
        if m:
            info = window_info(m.group(1))
            return self.json(200, info) if info else self.json(404, {"error": "gone"})
        m = re.fullmatch(r"/window/(0x[0-9a-f]{1,16})\.png", self.path)
        if m:
            g = window_info(m.group(1))
            if g is None:
                return self.json(404, {"error": "gone"})
            out = run(["grim", "-g", f"{g['x']},{g['y']} {g['w']}x{g['h']}", "-s", f"{min(1.0, MAX_WIDTH / g['w']):.3f}", "-t", "png", "-"], session_env(), timeout=15)
            return self.reply(200, out.stdout, "image/png") if out.returncode == 0 else self.json(404, {"error": "capture failed"})
        self.json(404, {"error": "unknown path"})

    def do_POST(self):
        if not self.guard():
            return
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
