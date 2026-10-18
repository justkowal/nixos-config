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
    fast mouse never queues up, everything else keeps its order."""

    def __init__(self, host, addr):
        self.host, self.addr = host, addr
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

    def run(self):
        while True:
            try:
                sock = socket.create_connection((self.host, INPUT_PORT), timeout=5)
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                sock.sendall((json.dumps({"window": self.addr}) + "\n").encode())
                while True:
                    self.wake.wait()
                    self.wake.clear()
                    with self.lock:
                        batch, self.events = self.events, []
                    if batch:
                        sock.sendall("".join(json.dumps(e) + "\n" for e in batch).encode())
            except OSError:
                self.wake.wait(1.0)


def gui(host, addr):
    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    gi.require_version("Gst", "1.0")
    from gi.repository import Adw, Gdk, GLib, Gst, Gtk

    Gst.init(None)
    name = NAMES.get(host, host)
    decoder = "vah264dec" if Gst.ElementFactory.find("vah264dec") else "avdec_h264"
    state = {"held_keys": set(), "held_buttons": set()}

    class Peek(Adw.Application):
        def __init__(self):
            super().__init__(application_id="lab.justkowal.Peek")

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
                f"padding: 2px 8px; font-family: '{tokens['type']['display']}'; font-size: 10px; }}"
            )
            Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

            width, height = 1280, 720
            try:
                info = json.loads(call(host, f"/window/{addr}/info"))
                width, height = min(info["w"], 1600), min(info["h"], 1000)
                title = info["title"]
            except (OSError, ValueError, KeyError):
                title = name
            self.win = Gtk.ApplicationWindow(application=self, default_width=width, default_height=height, title=title, decorated=False)

            self.pic = Gtk.Picture(content_fit=Gtk.ContentFit.CONTAIN, hexpand=True, vexpand=True, can_shrink=True)
            self.note = Gtk.Label(label="", css_classes=["dim-label"])
            badge = Gtk.Label(label=f"ON {name.upper()}", halign=Gtk.Align.END, valign=Gtk.Align.START, margin_top=8, margin_end=8)
            badge.add_css_class("badge")
            badge.set_can_target(False)
            overlay = Gtk.Overlay(child=self.pic)
            overlay.add_overlay(badge)
            overlay.add_overlay(self.note)
            self.win.set_child(overlay)

            self.sender = Sender(host, addr)
            motion = Gtk.EventControllerMotion()
            motion.connect("motion", lambda _c, x, y: self.sender.push({"m": self.norm(x, y)}))
            self.pic.add_controller(motion)
            click = Gtk.GestureClick(button=0)
            click.connect("pressed", self.on_button, 1)
            click.connect("released", self.on_button, 0)
            self.pic.add_controller(click)
            scroll = Gtk.EventControllerScroll(flags=Gtk.EventControllerScrollFlags.BOTH_AXES)
            scroll.connect("scroll", lambda _c, dx, dy: (self.sender.push({"a": [dx, dy]}), True)[1])
            self.pic.add_controller(scroll)
            keys = Gtk.EventControllerKey()
            keys.connect("key-pressed", self.on_key, 1)
            keys.connect("key-released", self.on_key, 0)
            self.win.add_controller(keys)
            self.win.connect("notify::is-active", self.on_focus)
            self.win.present()
            GLib.timeout_add(600, self.start_video)
            GLib.timeout_add(2000, self.refresh_title)

        def norm(self, x, y):
            paintable = self.pic.get_paintable()
            iw, ih = (paintable.get_intrinsic_width(), paintable.get_intrinsic_height()) if paintable else (0, 0)
            w, h = self.pic.get_width(), self.pic.get_height()
            if not (iw and ih and w and h):
                return [0.5, 0.5]
            scale = min(w / iw, h / ih)
            dw, dh = iw * scale, ih * scale
            return [(x - (w - dw) / 2) / dw, (y - (h - dh) / 2) / dh]

        def on_button(self, gesture, _n, x, y, down):
            code = BUTTONS.get(gesture.get_current_button())
            if code is None:
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

        def start_video(self):
            self.note.set_label("")
            self.pipeline = Gst.parse_launch(
                f"souphttpsrc location=http://{host}:{PORT}/window/{addr}/video is-live=true do-timestamp=true ! "
                f"h264parse ! {decoder} ! gtk4paintablesink name=sink sync=false"
            )
            self.pic.set_paintable(self.pipeline.get_by_name("sink").props.paintable)
            bus = self.pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message::error", lambda *_: self.restart("The stream stopped."))
            bus.connect("message::eos", lambda *_: self.restart("The window is gone or stopped sharing."))
            self.pipeline.set_state(Gst.State.PLAYING)
            return False

        def restart(self, why):
            self.pipeline.set_state(Gst.State.NULL)
            self.note.set_label(why)
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

    return Peek().run([])


def main():
    args = sys.argv[1:]
    if args == ["entries"]:
        json.dump(entries(), sys.stdout)
        return 0
    if len(args) == 2 and args[0] in NAMES:
        return gui(*args)
    print("usage: lab-peek entries | lab-peek HOST ADDRESS", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
