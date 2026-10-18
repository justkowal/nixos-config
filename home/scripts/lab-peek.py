#!/usr/bin/env python3
"""lab-peek: use a window of another machine of yours as if it were a local one.

  lab-peek entries          palette entries for every window on your other machines (JSON)
  lab-peek HOST ADDRESS     open the window: live hardware decoded video, every key and mouse event passed through

The other end is lab-peer. The window has no frame of its own and a small badge says where it lives.
Close it like any window, with your window manager.
"""

import concurrent.futures
import json
import os
import socket
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

CONF = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "lab"
PORT = 8766
INPUT_PORT = PORT + 1
NAMES = json.loads((CONF / "continuity.json").read_text())["names"]
BUTTONS = {1: 272, 2: 274, 3: 273, 8: 275, 9: 276}


def call(host, path, body=None, timeout=3):
    req = urllib.request.Request(f"http://{host}:{PORT}{path}", data=body, method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def entries():
    me = socket.gethostname()
    peers = [h for h in NAMES if h != me]

    def one(host):
        name = NAMES[host]
        try:
            rows = json.loads(call(host, "/windows", timeout=2))
        except (OSError, ValueError):
            # say so in the list instead of showing nothing, a silent miss looks like a bug
            return [{"title": f"{name.capitalize()} · not reachable, is lab-peer running there?", "group": f"On {name}",
                     "exec": "systemctl --user status lab-peer", "rank": 1}]
        out = []
        for w in sorted(rows, key=lambda r: (not r["visible"], r["workspace"])):
            where = "scratchpad" if w["workspace"] < 0 else f"workspace {w['workspace']}"
            tail = "" if w["visible"] else f"  ({where})"
            out.append({"title": f"{name.capitalize()} · {w['title']}{tail}", "group": f"On {name}",
                        "exec": f"lab peek {host} {w['addr']}", "rank": 1})
        return out

    with concurrent.futures.ThreadPoolExecutor(max(1, len(peers))) as pool:
        return [e for part in pool.map(one, peers) for e in part]


class Sender:
    """Input events to lab-peer over one TCP connection. Consecutive pointer moves are merged so a
    fast mouse never queues up, everything else keeps its order. The server answers with the state
    of the window over there (ok, hidden, gone)."""

    def __init__(self, host, addr, on_state):
        self.host, self.addr, self.on_state = host, addr, on_state
        self.events = []
        self.lock = threading.Lock()
        self.wake = threading.Event()
        threading.Thread(target=self.run, daemon=True).start()

    def push(self, ev):
        with self.lock:
            if "m" in ev and self.events and "m" in self.events[-1]:
                self.events[-1] = ev
            else:
                self.events.append(ev)
        self.wake.set()

    def listen(self, sock):
        for line in sock.makefile("r"):
            try:
                self.on_state(json.loads(line)["state"])
            except (ValueError, KeyError):
                pass

    def run(self):
        while True:
            try:
                sock = socket.create_connection((self.host, INPUT_PORT), timeout=5)
                sock.settimeout(None)
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                sock.sendall((json.dumps({"window": self.addr}) + "\n").encode())
                threading.Thread(target=self.listen, args=(sock,), daemon=True).start()
                while True:
                    self.wake.wait()
                    self.wake.clear()
                    with self.lock:
                        batch, self.events = self.events, []
                    if batch:
                        sock.sendall("".join(json.dumps(e) + "\n" for e in batch).encode())
            except OSError:
                self.wake.wait(1.0)


def gui(host, addr, child=False):
    import subprocess

    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    gi.require_version("Gst", "1.0")
    from gi.repository import Adw, Gdk, Gio, GLib, Gst, Gtk

    Gst.init(None)
    name = NAMES.get(host, host)
    # Measured on this hardware: software decode adds about 3 ms, the VA-API decoder about 20 ms because it
    # holds the newest frame back. Set LAB_PEEK_DECODER=vah264dec to decode on the GPU anyway (heavy video).
    want = os.environ.get("LAB_PEEK_DECODER", "avdec_h264 max-threads=1")
    decoder = want if Gst.ElementFactory.find(want.split()[0]) else "vah264dec"
    state = {"held_keys": set(), "held_buttons": set(), "window": "ok"}
    children = {}

    class Peek(Adw.Application):
        def __init__(self):
            # several viewers run side by side, so no single instance
            super().__init__(application_id="lab.justkowal.PeekDialog" if child else "lab.justkowal.Peek",
                             flags=Gio.ApplicationFlags.NON_UNIQUE)

        def do_activate(self):
            tokens = {"radius": {"sm": 8}, "type": {"display": "Departure Mono"}}
            try:
                raw = json.loads((CONF / "tokens.json").read_text())
                tokens["radius"].update(raw.get("radius", {}))
                tokens["type"].update(raw.get("type", {}))
            except (OSError, ValueError):
                pass
            css = Gtk.CssProvider()
            css.load_from_string(
                f".badge {{ background: alpha(@accent_bg_color, 0.92); color: @accent_fg_color; border-radius: {tokens['radius']['sm']}px; "
                f"padding: 2px 8px; font-family: '{tokens['type']['display']}'; font-size: 10px; }} "
                f".peek-note {{ background: alpha(black, 0.55); color: white; padding: 6px 12px; border-radius: {tokens['radius']['sm']}px; }}"
            )
            Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

            width, height, title = 1280, 720, name
            try:
                info = json.loads(call(host, f"/window/{addr}/info"))
                width, height, title = min(info["w"], 1600), min(info["h"], 1000), info["title"]
            except (OSError, ValueError, KeyError):
                pass
            self.win = Gtk.ApplicationWindow(application=self, default_width=width, default_height=height, title=title, decorated=False)

            self.pic = Gtk.Picture(content_fit=Gtk.ContentFit.CONTAIN, hexpand=True, vexpand=True, can_shrink=True)
            self.note = Gtk.Label(halign=Gtk.Align.CENTER, valign=Gtk.Align.END, margin_bottom=24, visible=False)
            self.note.add_css_class("peek-note")
            self.note.set_can_target(False)
            badge = Gtk.Label(label=f"ON {name.upper()}", halign=Gtk.Align.END, valign=Gtk.Align.START, margin_top=8, margin_end=8)
            badge.add_css_class("badge")
            badge.set_can_target(False)
            overlay = Gtk.Overlay(child=self.pic)
            overlay.add_overlay(badge)
            overlay.add_overlay(self.note)
            self.win.set_child(overlay)

            self.sender = Sender(host, addr, lambda s: GLib.idle_add(self.on_state, s))
            # the controllers sit on the overlay, so nothing drawn above the picture can swallow an event
            motion = Gtk.EventControllerMotion()
            motion.connect("motion", lambda _c, x, y: self.on_motion(x, y))
            overlay.add_controller(motion)
            click = Gtk.GestureClick(button=0)
            click.connect("pressed", self.on_button, 1)
            click.connect("released", self.on_button, 0)
            overlay.add_controller(click)
            scroll = Gtk.EventControllerScroll(flags=Gtk.EventControllerScrollFlags.BOTH_AXES)
            scroll.connect("scroll", lambda _c, dx, dy: (self.sender.push({"a": [dx, dy]}), True)[1])
            overlay.add_controller(scroll)
            keys = Gtk.EventControllerKey()
            keys.connect("key-pressed", self.on_key, 1)
            keys.connect("key-released", self.on_key, 0)
            self.win.add_controller(keys)
            self.win.connect("notify::is-active", self.on_focus)
            self.win.connect("close-request", self.on_close)
            self.win.present()
            GLib.timeout_add(500, self.start_video)
            GLib.timeout_add(2000, self.refresh_title)
            if not child:
                GLib.timeout_add(700, self.watch_children)

        def norm(self, x, y):
            paintable = self.pic.get_paintable()
            iw, ih = (paintable.get_intrinsic_width(), paintable.get_intrinsic_height()) if paintable else (0, 0)
            w, h = self.pic.get_width(), self.pic.get_height()
            if not (iw and ih and w and h):
                return [0.5, 0.5]
            scale = min(w / iw, h / ih)
            dw, dh = iw * scale, ih * scale
            return [(x - (w - dw) / 2) / dw, (y - (h - dh) / 2) / dh]

        def on_motion(self, x, y):
            self.sender.push({"m": self.norm(x, y)})

        def on_state(self, s):
            state["window"] = s
            if s == "gone":
                self.win.close()
            elif s == "hidden":
                self.say(f"Hidden on {name}. Click to bring it back.")
            else:
                self.say("")

        def say(self, text):
            self.note.set_label(text)
            self.note.set_visible(bool(text))

        def on_button(self, gesture, _n, x, y, down):
            code = BUTTONS.get(gesture.get_current_button())
            if code is None:
                return
            if state["window"] == "hidden":
                # the one input that moves workspaces over there, and only on an explicit click
                if down:
                    self.sender.push({"focus": 1})
                return
            self.sender.push({"m": self.norm(x, y)})
            (state["held_buttons"].add if down else state["held_buttons"].discard)(code)
            self.sender.push({"b": [code, down]})

        def on_key(self, _c, _keyval, keycode, _mods, down):
            code = keycode - 8
            (state["held_keys"].add if down else state["held_keys"].discard)(code)
            self.sender.push({"k": [code, down]})
            return True

        def on_focus(self, win, _p):
            if not win.is_active():
                # nothing stays pressed over there while this window is not receiving input
                for code in list(state["held_keys"]):
                    self.sender.push({"k": [code, 0]})
                for code in list(state["held_buttons"]):
                    self.sender.push({"b": [code, 0]})
                state["held_keys"].clear()
                state["held_buttons"].clear()

        def on_close(self, *_):
            for proc in children.values():
                proc.terminate()
            if getattr(self, "pipeline", None):
                self.pipeline.set_state(Gst.State.NULL)
            return False

        def start_video(self):
            self.pipeline = Gst.parse_launch(
                f"souphttpsrc location=http://{host}:{PORT}/window/{addr}/video is-live=true do-timestamp=true ! "
                f"h264parse ! {decoder} ! videoconvert ! video/x-raw,format=BGRx ! "
                f"gtk4paintablesink name=sink sync=false"
            )
            self.pic.set_paintable(self.pipeline.get_by_name("sink").props.paintable)
            bus = self.pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message::error", lambda *_: self.restart("The stream stopped."))
            bus.connect("message::eos", lambda *_: self.restart("The window stopped sharing."))
            self.pipeline.set_state(Gst.State.PLAYING)
            return False

        def restart(self, why):
            self.pipeline.set_state(Gst.State.NULL)
            if state["window"] != "hidden":
                self.say(why)
            GLib.timeout_add(1500, self.start_video)

        def refresh_title(self):
            def go():
                try:
                    info = json.loads(call(host, f"/window/{addr}/info"))
                    GLib.idle_add(self.win.set_title, info["title"])
                except (OSError, ValueError, KeyError):
                    pass

            threading.Thread(target=go, daemon=True).start()
            return True

        def watch_children(self):
            """A dialog or popup of the same app is another window over there, so it becomes another window here."""
            def go():
                try:
                    rows = json.loads(call(host, f"/window/{addr}/related", timeout=2))
                except (OSError, ValueError):
                    return
                live = {w["addr"] for w in rows}
                for w in rows:
                    if w["addr"] not in children and w["visible"]:
                        children[w["addr"]] = subprocess.Popen(["lab-peek", host, w["addr"], "--child"])
                for a in [a for a, p in children.items() if p.poll() is not None or a not in live]:
                    children.pop(a).terminate()

            threading.Thread(target=go, daemon=True).start()
            return True

    return Peek().run([])


def main():
    args = sys.argv[1:]
    if args == ["entries"]:
        json.dump(entries(), sys.stdout)
        return 0
    child = "--child" in args
    args = [a for a in args if a != "--child"]
    if len(args) == 2 and args[0] in NAMES:
        return gui(*args, child=child)
    print("usage: lab-peek entries | lab-peek HOST ADDRESS [--child]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
