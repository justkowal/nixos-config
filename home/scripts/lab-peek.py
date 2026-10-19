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


def own_name():
    me = socket.gethostname()
    return NAMES.get(me, me)


def post(host, path, body, timeout=4):
    return call(host, path, json.dumps(body).encode(), timeout=timeout)


def placeholder(addr, by):
    """What stays on screen where the window used to be: the window is being used on another machine."""
    import subprocess

    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Adw, Gdk, Gtk

    def bring_back(_btn=None):
        try:
            ip = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=5).stdout.split()[0]
            post(ip, f"/window/{addr}/unportal", {})
        except (OSError, IndexError, subprocess.SubprocessError):
            pass

    class App(Adw.Application):
        def __init__(self):
            super().__init__(application_id="lab.justkowal.Portal")

        def do_activate(self):
            Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.FORCE_DARK)
            tokens = {"radius": {"md": 12}, "type": {"ui": "Inter", "display": "Departure Mono"}}
            try:
                raw = json.loads((CONF / "tokens.json").read_text())
                tokens["radius"].update(raw.get("radius", {}))
                tokens["type"].update(raw.get("type", {}))
            except (OSError, ValueError):
                pass
            css = Gtk.CssProvider()
            css.load_from_string(
                f".portal-title {{ font-family: '{tokens['type']['display']}'; font-size: 11px; opacity: 0.55; letter-spacing: 1px; }} "
                f".portal-text {{ font-family: '{tokens['type']['ui']}'; font-size: 18px; }} "
                f".portal-button {{ border-radius: {tokens['radius']['md']}px; padding: 8px 18px; }}"
            )
            Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
            # the title ends with the address, lab-peer finds the placeholder by it when the window returns
            win = Gtk.ApplicationWindow(application=self, default_width=420, default_height=240, title=f"In use on {by} {addr}")
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
            kicker = Gtk.Label(label=f"ON {by.upper()}")
            kicker.add_css_class("portal-title")
            text = Gtk.Label(label=f"This app is being used on {by}")
            text.add_css_class("portal-text")
            box.append(kicker)
            box.append(text)
            button = Gtk.Button(label="Work on it here", halign=Gtk.Align.CENTER)
            button.add_css_class("suggested-action")
            button.add_css_class("portal-button")
            button.connect("clicked", bring_back)
            box.append(button)
            win.set_child(box)
            win.present()

    return App().run([])


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
    state = {"held_keys": set(), "held_buttons": set(), "window": "ok", "portal": False, "sent_size": None}
    children = {}
    use_portal = os.environ.get("LAB_PEEK_PORTAL", "1") != "0"

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
            # raw events: a gesture drops the release once the pointer moves far, which broke dragging, and a
            # scroll controller misses some touchpad events
            legacy = Gtk.EventControllerLegacy()
            legacy.connect("event", self.on_raw)
            overlay.add_controller(legacy)
            keys = Gtk.EventControllerKey()
            keys.connect("key-pressed", self.on_key, 1)
            keys.connect("key-released", self.on_key, 0)
            self.win.add_controller(keys)
            self.win.connect("notify::is-active", self.on_focus)
            self.win.connect("close-request", self.on_close)
            self.win.present()
            GLib.timeout_add(400, self.enter_portal)
            GLib.timeout_add(2000, self.refresh_title)
            if use_portal:
                GLib.timeout_add(500, self.follow_size)
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
            self.last = (x, y)
            self.sender.push({"m": self.norm(x, y)})

        def on_raw(self, _c, ev):
            kind = ev.get_event_type()
            if kind in (Gdk.EventType.BUTTON_PRESS, Gdk.EventType.BUTTON_RELEASE):
                x, y = getattr(self, "last", (0, 0))
                self.on_button(ev.get_button(), x, y, int(kind == Gdk.EventType.BUTTON_PRESS))
                return True
            if kind == Gdk.EventType.SCROLL:
                direction = ev.get_direction()
                if direction == Gdk.ScrollDirection.SMOOTH:
                    dx, dy = ev.get_deltas()
                else:
                    dx, dy = {Gdk.ScrollDirection.UP: (0, -1), Gdk.ScrollDirection.DOWN: (0, 1), Gdk.ScrollDirection.LEFT: (-1, 0), Gdk.ScrollDirection.RIGHT: (1, 0)}.get(direction, (0, 0))
                if dx or dy:
                    self.sender.push({"a": [dx, dy]})
                return True
            return False

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

        def on_button(self, button, x, y, down):
            code = BUTTONS.get(button)
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
            if state["portal"]:
                state["portal"] = False
                try:
                    post(host, f"/window/{addr}/unportal", {}, timeout=3)
                except OSError:
                    pass
            for proc in children.values():
                proc.terminate()
            if getattr(self, "pipeline", None):
                self.pipeline.set_state(Gst.State.NULL)
            self.closing = True
            if getattr(self, "audio", None):
                self.audio.set_state(Gst.State.NULL)
            return False

        def enter_portal(self):
            """Move the window to the headless output over there at this window's size, then start the video."""
            def go():
                ok = False
                if use_portal:
                    try:
                        w, h = max(self.pic.get_width(), 320), max(self.pic.get_height(), 200)
                        ok = json.loads(post(host, f"/window/{addr}/portal", {"w": w, "h": h, "by": own_name()}, timeout=6)).get("ok", False)
                        state["sent_size"] = (w, h)
                    except (OSError, ValueError):
                        ok = False
                state["portal"] = ok
                GLib.idle_add(self.start_video)

            threading.Thread(target=go, daemon=True).start()
            return False

        def follow_size(self):
            """The output over there follows this window, so the stream is always native size."""
            size = (self.pic.get_width(), self.pic.get_height())
            if state["portal"] and size[0] > 0 and size != state["sent_size"] and getattr(self, "seen", None) == size:
                state["sent_size"] = size
                threading.Thread(target=lambda: post(host, f"/window/{addr}/portal", {"w": size[0], "h": size[1], "by": own_name()}), daemon=True).start()
            self.seen = size
            return True

        def start_audio(self):
            """The remote app's sound, opus over http into the local sound server. Dialogs share the main window's."""
            if child or getattr(self, "closing", False) or os.environ.get("LAB_PEEK_AUDIO", "1") == "0":
                return False
            self.audio = Gst.parse_launch(
                f"souphttpsrc location=http://{host}:{PORT}/window/{addr}/audio is-live=true do-timestamp=true ! "
                f"oggdemux ! opusdec ! audioconvert ! audioresample ! "
                f"pulsesink buffer-time=40000 latency-time=10000 sync=false"
            )
            bus = self.audio.get_bus()
            bus.add_signal_watch()
            bus.connect("message::error", lambda *_: self.retry_audio())
            bus.connect("message::eos", lambda *_: self.retry_audio())
            self.audio.set_state(Gst.State.PLAYING)
            return False

        def retry_audio(self):
            self.audio.set_state(Gst.State.NULL)
            GLib.timeout_add(3000, self.start_audio)

        def start_video(self):
            if not getattr(self, "audio", None):
                self.start_audio()
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
                    if state["portal"] and not info.get("portal"):
                        # it was brought back over there, nothing to show here any more
                        state["portal"] = False
                        GLib.idle_add(self.win.close)
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
    if len(args) == 3 and args[0] == "--placeholder":
        return placeholder(args[1], args[2])
    child = "--child" in args
    args = [a for a in args if a != "--child"]
    if len(args) == 2 and args[0] in NAMES:
        return gui(*args, child=child)
    print("usage: lab-peek entries | lab-peek HOST ADDRESS [--child]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
