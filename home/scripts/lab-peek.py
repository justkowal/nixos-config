#!/usr/bin/env python3
"""lab-peek: look at a window on another machine of yours and poke it a little.

  lab-peek entries          palette entries for every window on your other machines (JSON)
  lab-peek HOST ADDRESS     open a live preview of that window

The other end is lab-peer. The preview window is clearly stamped with the machine it shows.
"""

import concurrent.futures
import json
import os
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

CONF = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "lab"
PORT = 8766
NAMES = json.loads((CONF / "continuity.json").read_text())["names"]


def call(host, path, body=None, timeout=3):
    req = urllib.request.Request(f"http://{host}:{PORT}{path}", data=body, method="POST" if body is not None else "GET")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def entries():
    import socket

    me = socket.gethostname()
    peers = [h for h in NAMES if h != me]

    def one(host):
        try:
            rows = json.loads(call(host, "/windows", timeout=2))
        except (OSError, ValueError):
            return []
        name = NAMES[host]
        out = []
        for w in sorted(rows, key=lambda r: (not r["visible"], r["workspace"])):
            where = "scratchpad" if w["workspace"] < 0 else f"workspace {w['workspace']}"
            tail = "" if w["visible"] else f"  ({where}, no preview)"
            out.append({"title": f"{name.capitalize()} · {w['title']}{tail}", "group": f"On {name}",
                        "exec": f"lab peek {host} {w['addr']}", "rank": 1})
        return out

    with concurrent.futures.ThreadPoolExecutor(max(1, len(peers))) as pool:
        return [e for part in pool.map(one, peers) for e in part]


def gui(host, addr):
    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Adw, Gdk, GLib, Gtk

    name = NAMES.get(host, host)
    shown = {"title": "", "gone": False}

    class Peek(Adw.Application):
        def __init__(self):
            super().__init__(application_id="lab.justkowal.Peek")

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
                f".badge {{ background: alpha(@accent_bg_color, 0.9); color: @accent_fg_color; border-radius: {tokens['radius']['md']}px; "
                f"padding: 3px 10px; font-family: '{tokens['type']['display']}'; font-size: 11px; }} "
                f".peek-frame {{ border: 2px solid alpha(@accent_bg_color, 0.8); border-radius: {tokens['radius']['md']}px; }}"
            )
            Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

            self.win = Adw.ApplicationWindow(application=self, default_width=960, default_height=640, title=f"{name}")
            view = Adw.ToolbarView()
            header = Adw.HeaderBar()
            badge = Gtk.Label(label=f"ON {name.upper()}")
            badge.add_css_class("badge")
            header.pack_start(badge)
            self.title = Gtk.Label(label="", ellipsize=3, hexpand=True, xalign=0)
            header.set_title_widget(self.title)
            view.add_top_bar(header)

            self.pic = Gtk.Picture(content_fit=Gtk.ContentFit.CONTAIN, hexpand=True, vexpand=True, can_shrink=True)
            self.note = Gtk.Label(label="Loading…", vexpand=True)
            self.stack = Gtk.Stack()
            frame = Gtk.Box()
            frame.add_css_class("peek-frame")
            frame.append(self.pic)
            self.stack.add_named(frame, "pic")
            self.stack.add_named(self.note, "note")
            self.stack.set_margin_start(12)
            self.stack.set_margin_end(12)
            view.set_content(self.stack)

            bar = Gtk.Box(spacing=6, margin_start=12, margin_end=12, margin_top=8, margin_bottom=10)
            for label, key in (("←", "Left"), ("→", "Right"), ("↑", "Up"), ("↓", "Down"), ("PgUp", "Prior"), ("PgDn", "Next"), ("Space", "space"), ("Enter", "Return")):
                b = Gtk.Button(label=label)
                b.connect("clicked", lambda _b, k=key: self.act("key", {"key": k}))
                bar.append(b)
            spacer = Gtk.Box(hexpand=True)
            bar.append(spacer)
            focus = Gtk.Button(label=f"Show on {name}")
            focus.connect("clicked", lambda _b: self.act("focus"))
            close = Gtk.Button(label="Close there")
            close.add_css_class("destructive-action")
            close.connect("clicked", lambda _b: self.act("close"))
            bar.append(focus)
            bar.append(close)
            view.add_bottom_bar(bar)
            self.win.set_content(view)

            keys = Gtk.EventControllerKey()
            keys.connect("key-pressed", self.on_key)
            self.win.add_controller(keys)
            self.win.present()
            self.tick()
            GLib.timeout_add(1200, self.tick)

        def on_key(self, _c, keyval, _code, _state):
            name_ = Gdk.keyval_name(keyval)
            if name_ == "Escape":
                self.win.close()
                return True
            if name_ in ("Left", "Right", "Up", "Down", "Prior", "Next", "space", "Return"):
                self.act("key", {"key": name_})
                return True
            return False

        def act(self, what, body=None):
            def go():
                try:
                    call(host, f"/window/{addr}/{what}", json.dumps(body or {}).encode(), timeout=5)
                except (OSError, ValueError):
                    pass

            threading.Thread(target=go, daemon=True).start()

        def tick(self):
            def fetch():
                try:
                    for w in json.loads(call(host, "/windows", timeout=4)):
                        if w["addr"] == addr:
                            GLib.idle_add(self.title.set_label, w["title"])
                            GLib.idle_add(self.win.set_title, f"{name} · {w['title']}")
                except (OSError, ValueError):
                    pass
                try:
                    png = call(host, f"/window/{addr}.png", timeout=6)
                    GLib.idle_add(self.show_png, png)
                except urllib.error.HTTPError as e:
                    why = json.loads(e.read() or b"{}").get("error", "unavailable")
                    GLib.idle_add(self.show_note, {"not visible": f"Not visible on {name} right now.\nSwitch to its workspace there, or use Show on {name}.", "gone": "This window was closed."}.get(why, f"Preview unavailable ({why})"))
                except OSError:
                    GLib.idle_add(self.show_note, f"{name.capitalize()} did not answer.")

            threading.Thread(target=fetch, daemon=True).start()
            return True

        def show_png(self, png):
            self.pic.set_paintable(Gdk.Texture.new_from_bytes(GLib.Bytes.new(png)))
            self.stack.set_visible_child_name("pic")

        def show_note(self, text):
            self.note.set_label(text)
            self.stack.set_visible_child_name("note")

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
