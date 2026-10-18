#!/usr/bin/env python3
"""lab-continuity: makes your machines share what happens at the desk.

Watches desktop notifications and the fingerprint reader on this machine, shows the fingerprint
wait in the island, and mirrors both to your other machines over Taildrop. The receiver is
lab-inbox. Nothing leaves your tailnet and no server is involved.
"""

import json
import os
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import gi
import hashlib

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab_bus  # noqa: E402

TAILSCALE = os.environ.get("TAILSCALE", "tailscale")
CONF = json.loads((Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "lab/continuity.json").read_text())
ME = socket.gethostname()
NAMES = CONF["names"]
MY_NAME = NAMES.get(ME, ME)
OUT = queue.Queue()
SENT = []

# process name to the name shown in the toast, first match wins
WAITERS = [
    ("hyprlock", "Lock screen"),
    ("sudo", "sudo"),
    ("pkexec", "pkexec"),
    ("su", "su"),
    ("polkit-agent-helper-1", "A system action"),
]


def publish(name, payload, priority="normal", ttl=30):
    try:
        lab_bus.request({"op": "publish", "event": {"name": name, "source": "continuity", "priority": priority, "ttl": ttl, "payload": payload}})
    except (OSError, ValueError):
        pass


def online_peers():
    """Other machines of yours that the roster says are reachable. Without a roster, try them all."""
    wanted = [h for h in NAMES if h != ME]
    try:
        roster = lab_bus.request({"op": "state"})["state"].get("roster.changed")
        devices = roster["payload"]["devices"] if roster else None
    except (OSError, ValueError, KeyError):
        devices = None
    if devices is None:
        return wanted
    up = {d["host"] for d in devices if d.get("online") and not d.get("self")}
    return [h for h in wanted if h in up]


def sender():
    tmp = Path(tempfile.mkdtemp(prefix="lab-continuity-", dir=os.environ.get("XDG_RUNTIME_DIR")))
    n = 0
    while True:
        kind, payload = OUT.get()
        n += 1
        f = tmp / f"{kind}-{int(time.time())}-{n}.json"
        f.write_text(json.dumps({"from": MY_NAME, **payload}))
        for peer in online_peers():
            subprocess.run([TAILSCALE, "file", "cp", str(f), f"{peer}:"], capture_output=True, timeout=20, check=False)
        f.unlink(missing_ok=True)


def mirror(kind, payload):
    OUT.put((kind, payload))


# ── notifications ────────────────────────────────────────────────────────────

def mirror_notification(msg):
    app, _rid, _icon, summary, body, _actions, hints, _timeout = msg.get_body().unpack()
    if app in CONF["ignore"] or "x-lab-mirror" in hints or hints.get("transient") is True:
        return
    now = time.time()
    SENT[:] = [t for t in SENT if now - t < 60]
    if len(SENT) >= 15:
        return
    SENT.append(now)
    mirror("notify", {"app": app or "App", "summary": summary, "body": body, "urgency": int(hints.get("urgency", 1))})


def watch_notifications():
    addr = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None)
    conn = Gio.DBusConnection.new_for_address_sync(
        addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None
    )
    conn.call_sync(
        "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring", "BecomeMonitor",
        GLib.Variant("(asu)", (["type='method_call',interface='org.freedesktop.Notifications',member='Notify'"], 0)),
        None, Gio.DBusCallFlags.NONE, -1, None,
    )

    def on_message(_c, msg, incoming):
        if incoming and msg.get_member() == "Notify":
            try:
                mirror_notification(msg)
            except (ValueError, TypeError) as e:
                print(f"lab-continuity: skipped a notification: {e}", file=sys.stderr, flush=True)
        return msg

    conn.add_filter(on_message)
    return conn


# ── fingerprint wait ─────────────────────────────────────────────────────────

def who_is_waiting():
    running = set()
    for p in Path("/proc").iterdir():
        if p.name.isdigit():
            try:
                running.add((p / "comm").read_text().strip())
            except OSError:
                pass
    return next((label for comm, label in WAITERS if comm in running), "An app")


def watch_fingerprint():
    conn = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    def selected(*_a):
        app = who_is_waiting()
        publish("auth.waiting", {"app": app, "host": MY_NAME}, "high", 20)
        mirror("auth", {"state": "waiting", "app": app})

    def status(_c, _s, _p, _i, _sig, params):
        result, done = params.unpack()
        if done:
            ok = result == "verify-match"
            publish("auth.done", {"ok": ok, "host": MY_NAME}, "high", 20)
            mirror("auth", {"state": "done", "ok": ok})

    for sig, cb in (("VerifyFingerSelected", selected), ("VerifyStatus", status)):
        conn.signal_subscribe("net.reactivated.Fprint", "net.reactivated.Fprint.Device", sig, None, None, Gio.DBusSignalFlags.NONE, cb)
    return conn


# ── clipboard ────────────────────────────────────────────────────────────────

RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
CLIP_MAX = 64 * 1024
CLIP_SENT = []


def wayland_env():
    env = dict(os.environ)
    if "WAYLAND_DISPLAY" not in env:
        socks = sorted(RUNTIME.glob("wayland-[0-9]"))
        if socks:
            env["WAYLAND_DISPLAY"] = socks[0].name
    return env


def clipboard_changed(text):
    if (RUNTIME / "lab-clip-paused").exists() or not text.strip() or len(text.encode()) > CLIP_MAX:
        return
    digest = hashlib.sha256(text.encode()).hexdigest()
    try:
        # lab-inbox writes the hash of what it just copied in, so it is never sent straight back
        if (RUNTIME / "lab-clip-last").read_text() == digest:
            return
    except OSError:
        pass
    now = time.time()
    CLIP_SENT[:] = [t for t in CLIP_SENT if now - t < 60]
    if len(CLIP_SENT) >= 10:
        return
    CLIP_SENT.append(now)
    mirror("clip", {"text": text})


def watch_clipboard():
    """wl-paste runs the handler on every change and the handler prints the text and a NUL. Password
    managers mark their copies with a mime type, those are never read."""
    handler = 'if wl-paste --list-types | grep -q x-kde-passwordManagerHint; then :; else wl-paste --no-newline --type text; fi; printf "\\0"'
    proc = subprocess.Popen(["wl-paste", "--watch", "sh", "-c", handler], stdout=subprocess.PIPE, env=wayland_env())

    def read():
        buf = b""
        while True:
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                return
            buf += chunk
            while b"\0" in buf:
                one, buf = buf.split(b"\0", 1)
                if one:
                    clipboard_changed(one.decode(errors="replace"))
            buf = buf[-(CLIP_MAX * 2):]

    threading.Thread(target=read, daemon=True).start()
    return proc


def main():
    keep = []
    threading.Thread(target=sender, daemon=True).start()
    if CONF["notifications"]:
        keep.append(watch_notifications())
    if CONF.get("clipboard"):
        keep.append(watch_clipboard())
    if CONF["fingerprint"]:
        try:
            keep.append(watch_fingerprint())
        except GLib.Error as e:
            print(f"lab-continuity: no system bus access for fprintd signals: {e}", file=sys.stderr, flush=True)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
