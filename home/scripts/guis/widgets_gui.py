#!/usr/bin/env python3
"""deskwidgets: a wallpaper-layer info column plus a toggleable dashboard, fed by widgets_providers."""

import argparse
import concurrent.futures
import glob
import hashlib
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request
from collections import deque

import cairo
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango  # noqa: E402
from gi.repository import Gtk4LayerShell as LS  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import widgets_providers as P  # noqa: E402

APP_ID = "lab.justkowal.Widgets"
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "deskwidgets")

CSS = """
window.dw-window { background: none; font-family: "%UI%"; }
.dw-desk { padding: 8px 4px; }
.dw-desk label { color: white; text-shadow: 0 1px 3px rgba(0,0,0,0.75); }
.dw-desk .dw-dim { color: rgba(255,255,255,0.72); }
.dw-desk progressbar trough { background: rgba(255,255,255,0.18); }
.dw-clock { font-family: "%DISPLAY%"; font-size: 64pt; font-weight: 400; font-feature-settings: "tnum"; }
.dw-colon { color: @accent_color; }
.dw-desk .dw-colon { color: @accent_color; text-shadow: none; }
.dw-desk .dw-clock { font-size: 72pt; }
.dw-date { font-size: 13pt; font-weight: 500; }
.dw-big { font-family: "%DISPLAY%"; font-size: 24pt; font-weight: 400; font-feature-settings: "tnum"; }
.dw-head { font-size: 9pt; font-weight: 700; letter-spacing: 1px; opacity: 0.6; }
.dw-dim { opacity: 0.65; }
.dw-num { font-feature-settings: "tnum"; }
.dw-mono { font-family: "%MONO%"; font-size: 9pt; }
.dw-ok { color: @success_color; }
.dw-warn { color: @warning_color; }
.dw-bad { color: @error_color; }
.dw-stale { opacity: 0.45; }
.dw-scrim { background: alpha(black, 0.45); }
.dw-sheet { background: alpha(@window_bg_color, 0.92); border-radius: %XL%px; padding: 28px 32px; }
.dw-section { padding: 14px 0; border-top: 1px solid alpha(@window_fg_color, 0.08); }
.dw-section.dw-first { border-top: none; padding-top: 0; }
.dw-col { min-width: 330px; }
progressbar.dw-thin trough, progressbar.dw-thin progress { min-height: 4px; border-radius: %BAR%px; }
progressbar.dw-hot progress { background: @error_color; }
progressbar.dw-mid progress { background: @warning_color; }
.dw-art { border-radius: %SM%px; }
.dw-row { padding: 3px 0; }
button.dw-link { padding: 2px 4px; min-height: 0; }
"""


def load_tokens():
    """~/.config/lab/tokens.json (home/lab/design.nix). Defaults match it so the column still looks right unswitched."""
    t = {"type": {"ui": "Inter", "display": "Departure Mono", "mono": "JetBrainsMono Nerd Font"},
         "radius": {"sm": 8, "md": 12, "lg": 18, "xl": 24}, "space": [4, 8, 12, 16, 24, 32]}
    path = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "lab", "tokens.json")
    try:
        with open(path) as f:
            raw = json.load(f)
        for key in ("type", "radius"):
            t[key].update(raw.get(key, {}))
        t["space"] = raw.get("space", t["space"])
    except (OSError, ValueError):
        pass
    return t


TOKENS = load_tokens()


def build_css():
    t = TOKENS
    subs = {"%UI%": t["type"]["ui"], "%DISPLAY%": t["type"]["display"], "%MONO%": t["type"]["mono"],
            "%XL%": t["radius"]["xl"], "%SM%": t["radius"]["sm"], "%BAR%": max(2, t["radius"]["sm"] // 4)}
    css = CSS
    for k, v in subs.items():
        css = css.replace(k, str(v))
    return css


def lbl(text, *classes, xalign=0.0, wrap=False, ellipsize=True, markup=False):
    # cap natural width, otherwise one long error line stretches the whole column
    w = Gtk.Label(xalign=xalign, max_width_chars=48)
    w.set_markup(text) if markup else w.set_text(str(text))
    for c in classes:
        w.add_css_class(c)
    if wrap:
        w.set_wrap(True)
    elif ellipsize:
        w.set_ellipsize(Pango.EllipsizeMode.END)
    return w


def hbox(*children, spacing=8):
    b = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing)
    for c in children:
        b.append(c)
    return b


def vbox(*children, spacing=4):
    b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing)
    for c in children:
        b.append(c)
    return b


def bar(pct, label=None, extra=""):
    pb = Gtk.ProgressBar(fraction=max(0.0, min(1.0, (pct or 0) / 100)), hexpand=True, valign=Gtk.Align.CENTER)
    pb.add_css_class("dw-thin")
    if pct and pct >= 90:
        pb.add_css_class("dw-hot")
    elif pct and pct >= 70:
        pb.add_css_class("dw-mid")
    if label is None:
        return pb
    name = lbl(label, "dw-dim")
    name.set_size_request(92, -1)
    return hbox(name, pb, lbl(f"{pct:.0f}%{extra}", "dw-num", xalign=1.0))


def ago(ts):
    if not ts:
        return "never"
    s = time.time() - ts
    if s < 90:
        return "now"
    if s < 5400:
        return f"{s / 60:.0f} min ago"
    if s < 172800:
        return f"{s / 3600:.0f} h ago"
    return f"{s / 86400:.0f} d ago"


def until(ts):
    s = max(0, ts - time.time())
    if s < 3600:
        return f"{s / 60:.0f} min"
    if s < 172800:
        return f"{s / 3600:.0f} h {s % 3600 / 60:.0f} min"
    return f"{s / 86400:.1f} d"


def human(n):
    for unit in ("", "k", "M", "G"):
        if abs(n) < 1000:
            return f"{n:.0f}{unit}"
        n /= 1000
    return f"{n:.1f}T"


def spawn(*cmd):
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def open_uri(uri):
    Gio.AppInfo.launch_default_for_uri(uri, None)


def link_row(child, uri):
    b = Gtk.Button(child=child)
    b.add_css_class("flat")
    b.add_css_class("dw-link")
    b.connect("clicked", lambda *_: open_uri(uri))
    return b


def clear(box):
    while (c := box.get_first_child()) is not None:
        box.remove(c)


# ── store + scheduling ───────────────────────────────────────────────────────

class Store:
    """name -> {data, ts, error, stale}. Updates arrive on the main loop only."""

    def __init__(self):
        self.items = {}
        self.listeners = {}
        os.makedirs(CACHE, exist_ok=True)
        for path in glob.glob(f"{CACHE}/*.json"):
            try:
                c = json.load(open(path))
                self.items[os.path.basename(path)[:-5]] = {"data": c["data"], "ts": c["ts"], "error": None, "stale": True}
            except (OSError, ValueError, KeyError):
                pass

    def subscribe(self, name, cb):
        self.listeners.setdefault(name, []).append(cb)
        if name in self.items:
            cb(self.items[name])

    def publish(self, name, data=None, error=None, persist=True):
        item = self.items.setdefault(name, {"data": None, "ts": 0, "error": None, "stale": False})
        if error is None:
            item.update(data=data, ts=time.time(), error=None, stale=False)
            if persist:
                try:
                    tmp = f"{CACHE}/{name}.json.tmp"
                    with open(tmp, "w") as f:
                        json.dump({"ts": item["ts"], "data": data}, f)
                    os.replace(tmp, f"{CACHE}/{name}.json")
                except OSError:
                    pass
        else:
            item.update(error=error, stale=item["data"] is not None)
        for cb in self.listeners.get(name, []):
            cb(item)
        return False


def on_battery():
    supplies = glob.glob("/sys/class/power_supply/*")
    mains = [p for p in supplies if P.read(f"{p}/type") == "Mains"]
    return bool(mains) and not any(P.read(f"{p}/online") == "1" for p in mains)


class Scheduler:
    def __init__(self, store, cfg):
        self.store, self.cfg = store, cfg
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=4, thread_name_prefix="dw")
        self.due = {n: 0 for n in P.PROVIDERS if n not in cfg.get("disabled", [])}
        self.busy = set()
        self.factor = 1
        GLib.timeout_add_seconds(1, self.tick)
        GLib.timeout_add_seconds(30, self.check_power)
        self.check_power()
        for name, fn in P.STREAMS.items():
            if name not in cfg.get("disabled", []):
                threading.Thread(target=fn, args=(self.stream_emit(name),), daemon=True).start()

    def check_power(self):
        self.factor = 3 if on_battery() else 1
        return True

    def stream_emit(self, name):
        return lambda d: GLib.idle_add(self.store.publish, name, d, None, False)

    def tick(self):
        now = time.monotonic()
        for name, due in self.due.items():
            if due <= now and name not in self.busy:
                self.busy.add(name)
                self.pool.submit(self.work, name)
        return True

    def work(self, name):
        fn, interval = P.PROVIDERS[name]
        try:
            data, err = fn(self.cfg), None
        except Exception as e:  # any provider failure becomes a stale card, never a crash
            data, err = None, f"{type(e).__name__}: {e}"[:160]
        GLib.idle_add(self.done, name, data, err, interval)

    def done(self, name, data, err, interval):
        self.busy.discard(name)
        # back off on errors so an unreachable host isn't hammered
        self.due[name] = time.monotonic() + interval * self.factor * (1 if err is None else 2)
        self.store.publish(name, data, err)
        return False

    def refresh(self, name):
        if name in self.due:
            self.due[name] = 0


# ── renderers: (box, data, compact) ──────────────────────────────────────────

WMO = [((0,), "clear", "Clear"), ((1, 2), "few-clouds", "Partly cloudy"), ((3,), "overcast", "Overcast"),
       ((45, 48), "fog", "Fog"), ((51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82), "showers", "Rain"),
       ((71, 73, 75, 77, 85, 86), "snow", "Snow"), ((95, 96, 99), "storm", "Thunderstorm")]


def wmo(code):
    for codes, icon, text in WMO:
        if code in codes:
            return f"weather-{icon}-symbolic", text
    return "weather-severe-alert-symbolic", "Unknown"


def aqi_text(v):
    if v is None:
        return "", ""
    for limit, text, cls in ((20, "good", "dw-ok"), (40, "fair", "dw-ok"), (60, "moderate", "dw-warn"),
                             (80, "poor", "dw-bad"), (100, "very poor", "dw-bad")):
        if v < limit:
            return text, cls
    return "extremely poor", "dw-bad"


def r_weather(box, d, compact):
    c = d["current"]
    icon_name, text = wmo(c["weather_code"])
    icon = Gtk.Image.new_from_icon_name(icon_name)
    icon.set_pixel_size(40)
    t = d["today"]
    box.append(hbox(icon, vbox(
        lbl(f"{c['temperature_2m']:.0f}°", "dw-big"),
        lbl(f"{text}, feels {c['apparent_temperature']:.0f}°", "dw-dim")), spacing=12))
    box.append(lbl(f"{t['temperature_2m_min']:.0f}° / {t['temperature_2m_max']:.0f}°   wind {c['wind_speed_10m']:.0f} km/h   "
                   f"humidity {c['relative_humidity_2m']}%", "dw-dim", "dw-num"))
    air = d.get("air") or {}
    if air:
        text, cls = aqi_text(air.get("european_aqi"))
        row = hbox(lbl(f"Air {text}", cls or "dw-dim"),
                   lbl(f"PM2.5 {air.get('pm2_5', 0):.0f}  PM10 {air.get('pm10', 0):.0f} µg/m³", "dw-dim", "dw-num"))
        box.append(row)
    if compact:
        return
    strip = hbox(spacing=18)
    for h in d["hourly"][1::2][:6]:
        ic = Gtk.Image.new_from_icon_name(wmo(h["code"])[0])
        strip.append(vbox(lbl(h["time"], "dw-dim", xalign=0.5), ic, lbl(f"{h['temp']:.0f}°", "dw-num", xalign=0.5),
                          lbl(f"{h['rain']}%", "dw-dim", "dw-num", xalign=0.5), spacing=2))
    box.append(strip)


def r_agenda(box, d, compact):
    events = d["events"][: 3 if compact else 8]
    if not events:
        box.append(lbl("Nothing in the next two days", "dw-dim"))
    today = time.localtime().tm_yday
    for e in events:
        st = time.localtime(e["start"])
        day = "" if st.tm_yday == today else ("Tomorrow " if st.tm_yday == today + 1 else time.strftime("%a ", st))
        when = (day or "Today ") + ("all day" if e["allDay"] else time.strftime("%H:%M", st))
        if not e["allDay"] and e["start"] <= time.time() < e["end"]:
            when = "Now"
        w = lbl(when, "dw-dim", "dw-num")
        w.set_size_request(118, -1)
        box.append(hbox(w, lbl(e["title"])))


def _limits(box, d, compact, unit):
    if d["source"] == "api":
        for w in d["windows"]:
            extra = f"  {until(w['resets'])}" if w.get("resets") and not compact else ""
            box.append(bar(w["pct"], w["label"], extra))
        if d.get("plan") and not compact:
            box.append(lbl(f"Plan: {d['plan']}", "dw-dim"))
    else:
        for w in d["windows"]:
            n = w.get(unit, 0)
            box.append(hbox(lbl(w["label"], "dw-dim"), lbl(f"{human(n)} {unit}", "dw-num", xalign=1.0)))
        if not compact:
            box.append(lbl(f"Local estimate: {d.get('reason', '')}", "dw-dim", wrap=True))


def r_claude(box, d, compact):
    _limits(box, d, compact, "tokens")


def r_gemini(box, d, compact):
    _limits(box, d, compact, "sessions")


CI_ICON = {"success": ("emblem-ok-symbolic", "dw-ok"), "failure": ("dialog-error-symbolic", "dw-bad"),
           "error": ("dialog-error-symbolic", "dw-bad"), "killed": ("process-stop-symbolic", "dw-warn"),
           "running": ("media-playback-start-symbolic", "dw-warn"), "pending": ("content-loading-symbolic", "dw-dim")}


def r_ci(box, d, compact):
    for p in d["pipelines"][: 3 if compact else 8]:
        icon_name, cls = CI_ICON.get(p["status"], ("dialog-question-symbolic", "dw-dim"))
        ic = Gtk.Image.new_from_icon_name(icon_name)
        ic.add_css_class(cls)
        text = vbox(lbl(p["message"] or p["event"]),
                    lbl(f"{p['repo']} #{p['number']}  {p['event']} on {p['branch']}  {ago(p['started'])}", "dw-dim"),
                    spacing=0)
        row = hbox(ic, text)
        box.append(row if compact else link_row(row, p["url"]))


def r_github(box, d, compact):
    for title, items in (("Review requested", d["review"]), ("Your open PRs", d["mine"])):
        box.append(lbl(f"{title}  {len(items)}", "dw-dim"))
        for p in items[:5]:
            row = hbox(lbl(f"{p['repo']}#{p['number']}", "dw-dim", "dw-num"),
                       lbl(("[draft] " if p["draft"] else "") + p["title"]))
            box.append(link_row(row, p["url"]))


def r_power(box, d, compact):
    state = "Off-peak" if d["offPeak"] else "Peak"
    box.append(hbox(lbl(state, "dw-ok" if d["offPeak"] else "dw-warn"),
                    lbl(f"{d['price']:.2f} PLN/kWh", "dw-num"),
                    lbl(f"{'ends' if d['offPeak'] else 'next off-peak'} in {until(time.time() + d['changeIn'])}", "dw-dim")))
    if not compact:
        box.append(lbl(f"{d['name']}: " + ", ".join(f"{w['start']}-{w['end']}" for w in d["windows"]), "dw-dim"))


def r_fleet(box, d, compact):
    f = d.get("fleet")
    if f:
        cls = {"online": "dw-ok", "partial": "dw-warn"}.get(f.get("class"), "dw-bad")
        box.append(lbl(f"Fleet {f.get('text', '')}", cls))
        if not compact and f.get("tooltip"):
            lines = [line for line in f["tooltip"].split("\n") if "Click" not in line and not line.startswith("──")]
            box.append(lbl("\n".join(lines).strip(), "dw-mono", ellipsize=False))
    focus = d.get("focus") or {}
    if focus.get("active"):
        left = f", {until(focus['until'])} left" if focus.get("until") else ""
        box.append(lbl(f"Focus on{left}", "dw-warn"))
    else:
        box.append(lbl("Focus off", "dw-dim"))
    pomo = d.get("pomodoro") or {}
    if pomo.get("status") in ("running", "paused"):
        rem = int(pomo.get("target_time", 0)) - time.time() if pomo["status"] == "running" else int(pomo.get("remaining_time", 0))
        box.append(lbl(f"Pomodoro {pomo.get('type', '')} {pomo['status']}, {max(0, rem) / 60:.0f} min", "dw-num"))
    if not compact:
        btn = Gtk.Button(label="Toggle focus")
        btn.connect("clicked", lambda *_: spawn("focus", "toggle"))
        btn.set_halign(Gtk.Align.START)
        box.append(btn)


def r_nix(box, d, compact):
    built_age = time.time() - d["built"]
    box.append(hbox(lbl(f"Generation {d['generation']}"),
                    lbl(f"built {ago(d['built'])}", "dw-warn" if built_age > 14 * 86400 else "dw-dim")))
    if d["rebootPending"]:
        box.append(lbl("Kernel changed, reboot pending", "dw-warn"))
    for i in d["oldestInputs"][:2]:
        stale = time.time() - i["modified"] > 30 * 86400
        box.append(hbox(lbl(i["name"], "dw-dim"), lbl(f"locked {ago(i['modified'])}", "dw-warn" if stale else "dw-dim", xalign=1.0)))
    box.append(bar(d["storeFsUsedPct"], "/nix fs"))


def r_backups(box, d, compact):
    r = d.get("restic")
    old = not r or time.time() - r > 36 * 3600
    box.append(hbox(lbl("Restic"), lbl(ago(r), "dw-bad" if old else "dw-ok", xalign=1.0)))
    s = d.get("snapshot")
    if s:
        box.append(hbox(lbl("Snapshot"), lbl(ago(s), "dw-warn" if time.time() - s > 3 * 3600 else "dw-ok", xalign=1.0)))
    for p in d["pools"]:
        box.append(bar(p["usedPct"], p["mount"], f" of {p['sizeGiB']} GiB" if not compact else ""))
    for dr in d.get("drives", []):
        temp = f"  {dr['temp']}°C" if dr.get("temp") else ""
        box.append(hbox(lbl(dr["model"], "dw-dim"),
                        lbl(("healthy" if dr["ok"] else "SMART warning " + ",".join(dr["warnings"])) + temp,
                            "dw-ok" if dr["ok"] else "dw-bad", xalign=1.0)))


def r_notifications(box, d, compact):
    if d is None:
        box.append(lbl("swaync not running", "dw-dim"))
        return
    dnd = Gtk.Switch(active=bool(d.get("dnd")), valign=Gtk.Align.CENTER)
    dnd.connect("state-set", lambda _s, on: spawn("swaync-client", "--dnd-on" if on else "--dnd-off") or False)
    open_btn = Gtk.Button(label="Open")
    open_btn.connect("clicked", lambda *_: spawn("swaync-client", "-t"))
    box.append(hbox(lbl(f"{d.get('count', 0)} unread", "dw-num", "dw-big"), Gtk.Box(hexpand=True),
                    lbl("Do not disturb", "dw-dim"), dnd, open_btn))


_art_lock = threading.Lock()


def art_path(url):
    if not url or not url.startswith("http"):
        return url if url and os.path.exists(url) else None
    path = os.path.join(CACHE, "art", hashlib.sha1(url.encode()).hexdigest())
    if os.path.exists(path):
        return path

    def fetch():
        with _art_lock:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            try:
                urllib.request.urlretrieve(url, path + ".tmp")
                os.replace(path + ".tmp", path)
            except OSError:
                pass
    threading.Thread(target=fetch, daemon=True).start()
    return None


def r_media(box, d, compact):
    if not d or not d.get("title") or d.get("status") == "Stopped":
        box.append(lbl("Nothing playing", "dw-dim"))
        return
    path = art_path(d.get("art"))
    size = 56 if compact else 96
    if path:
        pic = Gtk.Picture.new_for_filename(path)
        pic.set_content_fit(Gtk.ContentFit.COVER)
        pic.set_size_request(size, size)
        pic.add_css_class("dw-art")
        pic.set_overflow(Gtk.Overflow.HIDDEN)
    else:
        pic = Gtk.Image.new_from_icon_name("audio-x-generic-symbolic")
        pic.set_pixel_size(size // 2)
        pic.set_size_request(size, size)
    info = vbox(lbl(d["title"]), lbl(d.get("artist") or d.get("player", ""), "dw-dim"), spacing=2)
    info.set_valign(Gtk.Align.CENTER)
    info.set_hexpand(True)
    row = hbox(pic, info, spacing=12)
    if not compact:
        ctl = hbox(spacing=2)
        player = d.get("player")
        for icon, cmd in (("media-skip-backward-symbolic", "previous"),
                          ("media-playback-pause-symbolic" if d["status"] == "Playing" else "media-playback-start-symbolic", "play-pause"),
                          ("media-skip-forward-symbolic", "next")):
            b = Gtk.Button(icon_name=icon, valign=Gtk.Align.CENTER)
            b.add_css_class("flat")
            b.add_css_class("circular")
            b.connect("clicked", lambda _b, c=cmd, p=player: spawn("playerctl", *(["-p", p] if p else []), c))
            ctl.append(b)
        row.append(ctl)
    box.append(row)


RENDER = {"weather": r_weather, "agenda": r_agenda, "claude": r_claude, "gemini": r_gemini, "ci": r_ci,
          "github": r_github, "power": r_power, "fleet": r_fleet, "nix": r_nix, "backups": r_backups,
          "notifications": r_notifications, "media": r_media}


class Section(Gtk.Box):
    def __init__(self, store, name, title, compact=False, heading=True):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.add_css_class("dw-section")
        self.name, self.compact = name, compact
        self.age = lbl("", "dw-dim", xalign=1.0)
        if heading:
            self.append(hbox(self._head(title), self.age))
        self.body = vbox(spacing=4)
        self.append(self.body)
        if name in P.STREAMS:
            RENDER[name](self.body, None, compact)
        store.subscribe(name, self.update)

    @staticmethod
    def _head(title):
        w = lbl(title.upper(), "dw-head")
        w.set_hexpand(True)
        return w

    def update(self, item):
        clear(self.body)
        self.set_visible(True)
        if item["data"] is None and item["error"] is None and self.name in P.STREAMS:
            # streams emit None when the backing tool is gone
            RENDER[self.name](self.body, None, self.compact)
            return
        if item["data"] is None:
            # the wallpaper column is glanceable, errors belong on the dashboard
            self.set_visible(not self.compact)
            self.body.append(lbl(item["error"] or "loading", "dw-dim", wrap=True))
            return
        try:
            RENDER[self.name](self.body, item["data"], self.compact)
        except (KeyError, TypeError, ValueError) as e:
            self.body.append(lbl(f"render failed: {e}", "dw-bad", wrap=True))
        stale = item["stale"]
        self.body.remove_css_class("dw-stale") if not stale else self.body.add_css_class("dw-stale")
        self.age.set_text(("stale, " if stale else "") + ago(item["ts"]) if item["ts"] and self.name not in P.STREAMS else "")
        if item["error"]:
            self.age.set_tooltip_text(item["error"])


class Clock(Gtk.Box):
    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.hh = lbl("", "dw-clock", "dw-num")
        self.colon = lbl(":", "dw-clock", "dw-colon")
        self.mm = lbl("", "dw-clock", "dw-num")
        self.time = hbox(self.hh, self.colon, self.mm, spacing=0)
        self.date = lbl("", "dw-date")
        self.append(self.time)
        self.append(self.date)
        self.tick()
        GLib.timeout_add_seconds(1, self.tick)

    def tick(self):
        self.hh.set_text(time.strftime("%H"))
        self.mm.set_text(time.strftime("%M"))
        self.date.set_text(time.strftime("%A, %-d %B"))
        return True


class System(Gtk.Box):
    """cpu/gpu/mem history; keeps its own ring buffers so it can't be rebuilt per tick."""

    SERIES = (("cpu", "CPU", "@accent_color"), ("gpu", "GPU", "@warning_color"), ("mem", "RAM", "@success_color"))

    def __init__(self, store):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.add_css_class("dw-section")
        self.hist = {k: deque([0.0] * 90, maxlen=90) for k, *_ in self.SERIES}
        self.append(Section._head("System"))
        self.area = Gtk.DrawingArea(content_height=90, hexpand=True)
        self.area.set_draw_func(self.draw)
        self.append(self.area)
        self.legend = hbox(spacing=16)
        self.append(self.legend)
        self.temps = lbl("", "dw-dim", "dw-num")
        self.append(self.temps)
        store.subscribe("system", self.update)

    def update(self, item):
        d = item["data"]
        if not d or item["stale"]:
            return
        for k in self.hist:
            if d.get(k) is not None:
                self.hist[k].append(d[k])
        clear(self.legend)
        for k, name, _ in self.SERIES:
            if d.get(k) is not None:
                self.legend.append(lbl(f"{name} {d[k]:.0f}%", "dw-num"))
        t = "   ".join(f"{k} {v:.0f}°C" for k, v in d["temps"].items())
        self.temps.set_text(f"{t}   load {' '.join(d['load'])}   {d['memUsedGiB']} GiB used")
        self.area.queue_draw()

    def draw(self, area, cr, w, h):
        ctx = area.get_style_context()
        for k, _, color in self.SERIES:
            ok, rgba = ctx.lookup_color(color[1:])
            if not ok:
                rgba = Gdk.RGBA()
                rgba.parse("#888")
            cr.set_source_rgba(rgba.red, rgba.green, rgba.blue, 0.9)
            cr.set_line_width(1.5)
            pts = list(self.hist[k])
            step = w / (len(pts) - 1)
            for i, v in enumerate(pts):
                y = h - 2 - (h - 4) * v / 100
                cr.line_to(i * step, y) if i else cr.move_to(0, y)
            cr.stroke()


# ── windows ──────────────────────────────────────────────────────────────────

def layer_window(app, namespace, layer):
    win = Gtk.Window(application=app)
    win.set_decorated(False)
    LS.init_for_window(win)
    LS.set_namespace(win, namespace)
    LS.set_layer(win, layer)
    win.set_css_classes(["dw-window"])
    return win


class DesktopLayer:
    """Display-only column on the BOTTOM layer: above the wallpaper, below every window."""

    def __init__(self, app, store, cfg, monitor):
        self.win = win = layer_window(app, "deskwidgets", LS.Layer.BOTTOM)
        LS.set_monitor(win, monitor)
        LS.set_anchor(win, LS.Edge.TOP, True)
        LS.set_anchor(win, LS.Edge.RIGHT, True)
        compact = cfg["compact"]
        # same edge as the bar and the island, plus one inset step
        space = TOKENS["space"]
        edge = space[1] if compact else space[2]
        LS.set_margin(win, LS.Edge.TOP, space[3])
        LS.set_margin(win, LS.Edge.RIGHT, edge + space[3])
        LS.set_keyboard_mode(win, LS.KeyboardMode.NONE)
        col = vbox(spacing=0)
        col.add_css_class("dw-desk")
        col.set_size_request(300 if compact else 380, -1)
        clock = Clock()
        clock.time.set_halign(Gtk.Align.END)
        clock.date.set_xalign(1.0)
        col.append(clock)
        names = cfg["desktop"]
        titles = dict(TITLES)
        for n in names:
            col.append(Section(store, n, titles.get(n, n), compact=True))
        win.set_child(col)
        win.connect("realize", self.click_through)
        win.present()

    @staticmethod
    def click_through(win):
        win.get_surface().set_input_region(cairo.Region())


TITLES = [("agenda", "Agenda"), ("weather", "Weather"), ("power", "Electricity"), ("claude", "Claude"),
          ("gemini", "Gemini"), ("ci", "Woodpecker CI"), ("github", "GitHub"), ("media", "Now playing"),
          ("notifications", "Notifications"), ("fleet", "Fleet and focus"), ("nix", "Nix"), ("backups", "Backups and storage")]


class Dashboard:
    def __init__(self, app, store, sched, cfg):
        self.sched = sched
        self.win = win = layer_window(app, "deskwidgets-dashboard", LS.Layer.OVERLAY)
        for e in (LS.Edge.TOP, LS.Edge.BOTTOM, LS.Edge.LEFT, LS.Edge.RIGHT):
            LS.set_anchor(win, e, True)
        LS.set_exclusive_zone(win, -1)
        compact = cfg["compact"]
        t = dict(TITLES)
        layout = ([["agenda", "weather", "power", "claude", "gemini", "media"],
                   ["ci", "github", "system", "notifications", "fleet", "nix", "backups"]] if compact else
                  [["agenda", "weather", "power", "media"],
                   ["claude", "gemini", "ci", "github"],
                   ["system", "notifications", "fleet", "nix", "backups"]])
        cols = hbox(spacing=40)
        cols.set_homogeneous(True)
        for i, names in enumerate(layout):
            col = vbox(spacing=0)
            col.add_css_class("dw-col")
            col.set_valign(Gtk.Align.START)
            if i == 0:
                col.append(Clock())
            for n in names:
                s = System(store) if n == "system" else Section(store, n, t[n])
                if col.get_first_child() is None:
                    s.add_css_class("dw-first")
                col.append(s)
            cols.append(col)
        sheet = Gtk.ScrolledWindow(child=cols, propagate_natural_width=True, propagate_natural_height=True,
                                   hscrollbar_policy=Gtk.PolicyType.NEVER)
        sheet.add_css_class("dw-sheet")
        sheet.set_halign(Gtk.Align.CENTER)
        sheet.set_valign(Gtk.Align.CENTER)
        sheet.set_margin_top(32)
        sheet.set_margin_bottom(32)
        self.scrim = Gtk.Box(hexpand=True, vexpand=True)
        self.scrim.add_css_class("dw-scrim")
        overlay = Gtk.Overlay(child=self.scrim)
        overlay.add_overlay(sheet)
        win.set_child(overlay)

        click = Gtk.GestureClick()
        click.connect("pressed", self.on_click)
        self.scrim.add_controller(click)
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_key)
        win.add_controller(keys)

    def on_click(self, *_):
        self.hide()

    def on_key(self, _c, keyval, *_):
        if keyval == Gdk.KEY_Escape:
            self.hide()
            return True
        if keyval in (Gdk.KEY_r, Gdk.KEY_F5):
            for n in P.PROVIDERS:
                self.sched.refresh(n)
            return True
        return False

    def show(self):
        LS.set_keyboard_mode(self.win, LS.KeyboardMode.EXCLUSIVE)
        self.win.present()

    def hide(self):
        LS.set_keyboard_mode(self.win, LS.KeyboardMode.NONE)
        self.win.set_visible(False)

    def toggle(self):
        self.hide() if self.win.get_visible() else self.show()


class App(Adw.Application):
    def __init__(self, cfg):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.cfg = cfg
        self.dash = None
        self.desks = {}

    def do_startup(self):
        Adw.Application.do_startup(self)
        Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.PREFER_DARK)
        css = Gtk.CssProvider()
        css.load_from_string(build_css())
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)
        self.store = Store()
        self.sched = Scheduler(self.store, self.cfg)
        self.dash = Dashboard(self, self.store, self.sched, self.cfg)
        # exposed so the hyprland bind can use gdbus instead of paying python startup per keypress
        for name in ("toggle", "show", "hide"):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", lambda _a, _p, n=name: getattr(self.dash, n)())
            self.add_action(action)
        monitors = Gdk.Display.get_default().get_monitors()
        monitors.connect("items-changed", lambda *_: self.sync_monitors())
        self.sync_monitors()
        self.hold()

    def sync_monitors(self):
        want = self.cfg.get("monitors") or []
        current = {}
        monitors = Gdk.Display.get_default().get_monitors()
        for i in range(monitors.get_n_items()):
            m = monitors.get_item(i)
            if not want or m.get_connector() in want:
                current[m.get_connector()] = m
        for conn in list(self.desks):
            if conn not in current:
                self.desks.pop(conn).win.destroy()
        for conn, m in current.items():
            if conn not in self.desks:
                self.desks[conn] = DesktopLayer(self, self.store, self.cfg, m)

    def do_command_line(self, cmdline):
        args = cmdline.get_arguments()[1:]
        cmd = next((a for a in args if a in ("toggle", "show", "hide")), None)
        if cmd:
            getattr(self.dash, cmd)()
        return 0


def load_cfg(path):
    cfg = {"lat": 50.06, "lon": 19.94, "place": "Kraków", "compact": False, "monitors": [], "disabled": [],
           "desktop": ["agenda", "weather", "claude", "gemini", "ci", "media", "power"],
           "flakeDir": os.path.expanduser("~/nixos-config"), "textfileDir": "/var/lib/node-exporter-textfile",
           "snapDir": "/home/.snapshots",
           "tariff": {"name": "G12", "windows": [{"start": "22:00", "end": "06:00"}, {"start": "13:00", "end": "15:00"}],
                      "pricePeak": 1.10, "priceOffPeak": 0.70},
           "woodpecker": {"url": "https://ci.lab", "tokenFile": "/run/secrets/woodpecker_widget_token",
                          "repos": ["justkowal/nixos-configs"]}}
    if path:
        with open(path) as f:
            cfg.update(json.load(f))
    return cfg


def main():
    ap = argparse.ArgumentParser(prog="deskwidgets")
    ap.add_argument("command", nargs="?", choices=["run", "toggle", "show", "hide"], default="run")
    ap.add_argument("--config")
    ap.add_argument("--dump", nargs="*", metavar="PROVIDER", help="run providers once, print JSON, exit")
    args = ap.parse_args()
    cfg = load_cfg(args.config)
    if args.dump is not None:
        out = {}
        for name in args.dump or [n for n in P.PROVIDERS if n not in cfg["disabled"]]:
            fn = P.PROVIDERS[name][0]
            if name == "system":
                fn(cfg)
                time.sleep(0.5)
            try:
                out[name] = fn(cfg)
            except Exception as e:
                out[name] = {"error": f"{type(e).__name__}: {e}"}
        json.dump(out, sys.stdout, indent=2, ensure_ascii=False, default=str)
        print()
        return 0
    return App(cfg).run([sys.argv[0], args.command])


if __name__ == "__main__":
    sys.exit(main())
