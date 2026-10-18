#!/usr/bin/env python3
"""lab-peer: lets your other machines look at this machine's windows.

Listens on this machine's tailnet address only. A request is served only when Tailscale says the
caller is another device of the same user, so there is no token to share. It can list windows,
send a picture of a visible one, focus or close it, and press a short list of keys in it.
"""

import json
import os
import re
import socket
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TAILSCALE = os.environ.get("TAILSCALE", "tailscale")
PORT = int(os.environ.get("LAB_PEER_PORT", "8766"))
MAX_WIDTH = 1280
ADDR_RE = re.compile(r"0x[0-9a-f]{1,16}")
# hyprland key names, nothing that types text or runs commands
KEYS = {"space", "Return", "Escape", "Left", "Right", "Up", "Down", "Prior", "Next", "Home", "End"}
shots = threading.Semaphore(2)
allowed = {}
lock = threading.Lock()


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
    out = run([TAILSCALE, "status", "--json"])
    return json.loads(out.stdout)["Self"]["UserID"]


def is_my_device(ip, me):
    """True when Tailscale says `ip` belongs to another untagged device of this user."""
    with lock:
        if ip in allowed:
            return allowed[ip]
    out = run([TAILSCALE, "whois", "--json", ip])
    try:
        node = json.loads(out.stdout)["Node"]
        ok = node.get("User") == me and not node.get("Tags")
    except (ValueError, KeyError):
        ok = False
    with lock:
        allowed[ip] = ok
    return ok


def windows():
    visible_ws = {m["activeWorkspace"]["id"] for m in hypr_json("monitors")}
    rows = []
    for c in hypr_json("clients"):
        if not c.get("mapped") or c.get("hidden") or not c.get("title"):
            continue
        ws = c["workspace"]["id"]
        rows.append({
            "addr": c["address"], "title": c["title"][:120], "class": c.get("class", ""),
            "workspace": ws, "visible": ws in visible_ws, "focused": c.get("focusHistoryID") == 0,
        })
    return rows


def picture(addr):
    for c in hypr_json("clients"):
        if c["address"] == addr:
            break
    else:
        return None, "gone"
    if c["workspace"]["id"] not in {m["activeWorkspace"]["id"] for m in hypr_json("monitors")}:
        return None, "not visible"
    (x, y), (w, h) = c["at"], c["size"]
    if w < 1 or h < 1:
        return None, "gone"
    scale = min(1.0, MAX_WIDTH / w)
    with shots:
        out = run(["grim", "-g", f"{x},{y} {w}x{h}", "-s", f"{scale:.3f}", "-t", "png", "-"], session_env(), timeout=15)
    return (out.stdout, None) if out.returncode == 0 and out.stdout else (None, "capture failed")


class Handler(BaseHTTPRequestHandler):
    server_version = "lab-peer"
    me = None

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
        if is_my_device(self.client_address[0], self.me):
            return True
        self.json(403, {"error": "not one of your devices"})
        return False

    def do_GET(self):
        if not self.guard():
            return
        if self.path == "/hello":
            return self.json(200, {"host": socket.gethostname()})
        if self.path == "/windows":
            return self.json(200, windows())
        m = re.fullmatch(r"/window/(0x[0-9a-f]{1,16})\.png", self.path)
        if m:
            png, why = picture(m.group(1))
            return self.reply(200, png, "image/png") if png else self.json(404, {"error": why})
        self.json(404, {"error": "unknown path"})

    def do_POST(self):
        if not self.guard():
            return
        m = re.fullmatch(r"/window/(0x[0-9a-f]{1,16})/(focus|close|key)", self.path)
        if not m or not ADDR_RE.fullmatch(m.group(1)):
            return self.json(404, {"error": "unknown path"})
        addr, action = m.groups()
        env = session_env()
        if action == "focus":
            run(["hyprctl", "dispatch", "focuswindow", f"address:{addr}"], env)
        elif action == "close":
            run(["hyprctl", "dispatch", "closewindow", f"address:{addr}"], env)
        else:
            try:
                key = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 256)))["key"]
            except (ValueError, KeyError, TypeError):
                return self.json(400, {"error": "bad body"})
            if key not in KEYS:
                return self.json(400, {"error": "key not allowed"})
            run(["hyprctl", "dispatch", "sendshortcut", f",{key},address:{addr}"], env)
        self.json(200, {"ok": True})


def main():
    Handler.me = my_user_id()
    ip = run([TAILSCALE, "ip", "-4"]).stdout.decode().split()[0]
    ThreadingHTTPServer((ip, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
