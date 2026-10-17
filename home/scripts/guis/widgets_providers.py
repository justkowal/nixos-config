"""Data sources for deskwidgets. Every provider is a plain function cfg -> dict that may raise."""

import datetime as dt
import glob
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

HOME = os.path.expanduser("~")
RUN = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")


def http_json(url, headers=None, body=None, timeout=8):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={"User-Agent": "deskwidgets", **(headers or {})})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def run(cmd, timeout=10):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=True).stdout


def read(path, default=None):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def parse_iso(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


# ── weather + air ────────────────────────────────────────────────────────────

def weather(cfg):
    q = urllib.parse.urlencode({
        "latitude": cfg["lat"], "longitude": cfg["lon"], "timezone": "auto", "forecast_hours": 12,
        "current": "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m,is_day",
        "hourly": "temperature_2m,precipitation_probability,weather_code",
        "daily": "temperature_2m_max,temperature_2m_min,sunrise,sunset", "forecast_days": 1,
    })
    w = http_json(f"https://api.open-meteo.com/v1/forecast?{q}")
    aq = {}
    try:
        q = urllib.parse.urlencode({"latitude": cfg["lat"], "longitude": cfg["lon"],
                                    "current": "pm2_5,pm10,european_aqi", "timezone": "auto"})
        aq = http_json(f"https://air-quality-api.open-meteo.com/v1/air-quality?{q}")["current"]
    except (OSError, KeyError, ValueError):
        pass
    h = w["hourly"]
    return {
        "place": cfg["place"],
        "current": w["current"],
        "today": {k: w["daily"][k][0] for k in w["daily"] if k != "time"},
        "hourly": [{"time": t[11:16], "temp": tp, "rain": pp, "code": c}
                   for t, tp, pp, c in zip(h["time"], h["temperature_2m"], h["precipitation_probability"], h["weather_code"])],
        "air": aq,
    }


# ── AI limits ────────────────────────────────────────────────────────────────

CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", f"{HOME}/.cache"), "deskwidgets")
HISTORY_DAYS = 14


def _hist_path(name):
    return os.path.join(CACHE, "history", f"{name}.jsonl")


def hist_append(name, ts, pcts):
    """One line per successful api poll: {ts, pct: {window label: percent}}. Trimmed to HISTORY_DAYS."""
    path = _hist_path(name)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write(json.dumps({"ts": ts, "pct": pcts}) + "\n")
        if os.path.getsize(path) > 200_000:
            keep = hist_read(name, ts - HISTORY_DAYS * 86400)
            with open(path, "w") as f:
                f.writelines(json.dumps(r) + "\n" for r in keep)
    except OSError:
        pass


def hist_read(name, since):
    rows = []
    try:
        with open(_hist_path(name)) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("ts", 0) >= since:
                    rows.append(r)
    except OSError:
        pass
    return rows


def pct_series(name, now):
    """label -> [[ts, pct]] for the last week, plus the last known reading per label."""
    rows = hist_read(name, now - 7 * 86400)
    series = {}
    for r in rows:
        for label, v in r["pct"].items():
            series.setdefault(label, []).append([r["ts"], v])
    last = {label: pts[-1] for label, pts in series.items()}
    return series, last


def _claude_local(now):
    """One pass over the session logs: tokens per hour for a week plus the exact 5 h and week sums."""
    week, five = now - 7 * 86400, now - 5 * 3600
    start = int(week // 3600) * 3600
    hourly = [0] * 170
    five_sum = week_sum = 0
    for p in glob.glob(f"{HOME}/.claude/projects/*/*.jsonl"):
        if os.path.getmtime(p) < week:
            continue
        with open(p, errors="ignore") as f:
            for line in f:
                if '"usage"' not in line:
                    continue
                try:
                    e = json.loads(line)
                    ts = parse_iso(e["timestamp"])
                    u = e["message"]["usage"]
                except (ValueError, KeyError, TypeError):
                    continue
                if ts < week:
                    continue
                n = u.get("input_tokens", 0) + u.get("output_tokens", 0) + u.get("cache_creation_input_tokens", 0)
                hourly[min(169, int((ts - start) // 3600))] += n
                week_sum += n
                if ts >= five:
                    five_sum += n
    return {"5 h": five_sum, "Week": week_sum}, hourly[:169]


def _age_text(seconds):
    seconds = max(0, seconds)
    if seconds < 5400:
        return f"{int(seconds // 60)} min"
    if seconds < 172800:
        return f"{int(seconds // 3600)} h"
    return f"{int(seconds // 86400)} d"


def _offline_reason(e, who):
    """Say what is wrong and what to do, in one short line the column can show."""
    if isinstance(e, FileNotFoundError):
        return f"Not signed in to {who}"
    if isinstance(e, urllib.error.URLError):
        return "Usage endpoint unreachable"
    if isinstance(e, RuntimeError):
        return str(e)
    return f"{who} credentials unreadable"


def _budget_pct(cfg, label, tokens):
    """Optional user-set budgets (tokens) turn raw usage into an estimated percentage."""
    key = {"5 h": "fiveHour", "Week": "week"}.get(label)
    limit = ((cfg.get("budgets") or {}).get("claude") or {}).get(key)
    return 100.0 * tokens / limit if limit else None


def claude(cfg):
    now = time.time()
    tokens, hourly = _claude_local(now)
    out = {"hourly": hourly}
    try:
        creds = json.load(open(f"{HOME}/.claude/.credentials.json"))["claudeAiOauth"]
        # never refresh here: claude code rotates the refresh token and would get logged out
        if creds["expiresAt"] / 1000 < now:
            raise RuntimeError(f"Claude login expired {_age_text(now - creds['expiresAt'] / 1000)} ago, run claude once")
        u = http_json("https://api.anthropic.com/api/oauth/usage", {
            "Authorization": f"Bearer {creds['accessToken']}", "anthropic-beta": "oauth-2025-04-20"})
        labels = {"five_hour": "5 h", "seven_day": "Week", "seven_day_opus": "Week Opus", "seven_day_sonnet": "Week Sonnet"}
        windows = [{"label": labels.get(k, k), "pct": v["utilization"], "tokens": tokens.get(labels.get(k, k)),
                    "resets": parse_iso(v["resets_at"]) if v.get("resets_at") else None}
                   for k, v in u.items() if isinstance(v, dict) and v.get("utilization") is not None]
        hist_append("claude", now, {w["label"]: w["pct"] for w in windows})
        out.update(source="api", plan=creds.get("subscriptionType"), windows=windows)
    except (OSError, KeyError, ValueError, RuntimeError, urllib.error.URLError) as e:
        windows = []
        for label in ("5 h", "Week"):
            est = _budget_pct(cfg, label, tokens[label])
            windows.append({"label": label, "tokens": tokens[label], "pct": est, "estimate": est is not None})
        out.update(source="local", reason=_offline_reason(e, "Claude Code"), windows=windows)
    series, last = pct_series("claude", now)
    out.update(pct_history=series, last_api=last)
    return out


_gemini_project = None


def _gemini_conversations():
    """Both installs write here: the standalone app and the IDE."""
    return glob.glob(f"{HOME}/.gemini/antigravity/conversations/*") + glob.glob(f"{HOME}/.gemini/antigravity-ide/conversations/*")


def gemini(cfg):
    global _gemini_project
    now = time.time()
    base = "https://cloudcode-pa.googleapis.com/v1internal"
    out = {}
    try:
        tok = json.load(open(f"{HOME}/.gemini/jetski-standalone-oauth-token"))["token"]
        if tok.get("expiry") and parse_iso(tok["expiry"]) < now:
            raise RuntimeError(f"Antigravity login expired {_age_text(now - parse_iso(tok['expiry']))} ago, send a prompt there")
        hdr = {"Authorization": f"Bearer {tok['access_token']}"}
        if _gemini_project is None:
            r = http_json(f"{base}:loadCodeAssist", hdr, {"metadata": {"ideType": "ANTIGRAVITY"}})
            _gemini_project = r.get("cloudaicompanionProject", "")
        r = http_json(f"{base}:fetchAvailableModels", hdr, {"project": _gemini_project} if _gemini_project else {})
        models = []
        for name, m in (r.get("models") or {}).items():
            q = m.get("quotaInfo") or {}
            if "remainingFraction" in q:
                models.append({"label": m.get("displayName", name), "pct": 100 * (1 - q["remainingFraction"]),
                               "resets": parse_iso(q["resetTime"]) if q.get("resetTime") else None})
        if not models:
            raise RuntimeError("no quota info in response")
        models.sort(key=lambda m: -m["pct"])
        hist_append("gemini", now, {m["label"]: m["pct"] for m in models})
        out.update(source="api", windows=models[:4])
    except (OSError, KeyError, ValueError, RuntimeError, urllib.error.URLError) as e:
        mt = [os.path.getmtime(p) for p in _gemini_conversations()]
        out.update(source="local", reason=_offline_reason(e, "Antigravity"), windows=[
            {"label": "5 h", "sessions": sum(t > now - 5 * 3600 for t in mt)},
            {"label": "Week", "sessions": sum(t > now - 7 * 86400 for t in mt)},
        ])
    # conversations per day for two weeks: the only usage signal gemini leaves on disk
    days = [0] * HISTORY_DAYS
    midnight = time.mktime(time.localtime(now)[:3] + (0, 0, 0, 0, 0, -1))
    for p in _gemini_conversations():
        i = int((midnight + 86400 - os.path.getmtime(p)) // 86400)
        if 0 <= i < HISTORY_DAYS:
            days[HISTORY_DAYS - 1 - i] += 1
    series, last = pct_series("gemini", now)
    out.update(daily=days, pct_history=series, last_api=last)
    return out


# ── CI + code review ─────────────────────────────────────────────────────────

_wp_ids = {}


def ci(cfg):
    wp = cfg["woodpecker"]
    token = read(wp["tokenFile"])
    if not token:
        raise RuntimeError(f"no token at {wp['tokenFile']}")
    hdr = {"Authorization": f"Bearer {token}"}
    out = []
    for repo in wp["repos"]:
        if repo not in _wp_ids:
            _wp_ids[repo] = http_json(f"{wp['url']}/api/repos/lookup/{repo}", hdr)["id"]
        for p in http_json(f"{wp['url']}/api/repos/{_wp_ids[repo]}/pipelines?perPage=6", hdr):
            out.append({"repo": repo.split("/")[-1], "number": p["number"], "status": p["status"],
                        "event": p.get("event"), "branch": p.get("branch"),
                        "message": (p.get("message") or "").split("\n")[0][:70],
                        "started": p.get("started") or p.get("created"), "finished": p.get("finished"),
                        "url": f"{wp['url']}/repos/{_wp_ids[repo]}/pipeline/{p['number']}"})
    out.sort(key=lambda p: -(p["started"] or 0))
    return {"pipelines": out[:8], "running": sum(p["status"] in ("running", "pending") for p in out)}


def github(cfg):
    fields = "repository,number,title,url,updatedAt"
    review = json.loads(run(["gh", "search", "prs", "--review-requested=@me", "--state=open", "--json", fields, "--limit", "8"], 20))
    mine = json.loads(run(["gh", "search", "prs", "--author=@me", "--state=open", "--json", fields + ",isDraft", "--limit", "8"], 20))
    slim = lambda p: {"repo": p["repository"]["name"], "number": p["number"], "title": p["title"][:70], "url": p["url"],
                      "draft": p.get("isDraft", False)}
    return {"review": [slim(p) for p in review], "mine": [slim(p) for p in mine]}


# ── calendar ─────────────────────────────────────────────────────────────────

def agenda(cfg):
    import gi
    gi.require_version("EDataServer", "1.2")
    gi.require_version("ECal", "2.0")
    gi.require_version("ICalGLib", "3.0")
    from gi.repository import ECal, EDataServer, GLib, ICalGLib

    start = int(time.time()) - 3600
    end = start + 2 * 86400
    utc = ICalGLib.Timezone.get_utc_timezone()
    events = []

    def stamp(t):
        if t.is_date():
            return dt.datetime(t.get_year(), t.get_month(), t.get_day()).timestamp()
        return t.as_timet_with_zone(t.get_timezone() or utc)

    def collect(icomp, istart, iend, *_):
        events.append({"title": icomp.get_summary() or "(no title)", "start": stamp(istart), "end": stamp(iend),
                       "allDay": istart.is_date(), "location": icomp.get_location() or ""})
        return True

    registry = EDataServer.SourceRegistry.new_sync(None)
    for src in registry.list_enabled(EDataServer.SOURCE_EXTENSION_CALENDAR):
        try:
            client = ECal.Client.connect_sync(src, ECal.ClientSourceType.EVENTS, 10, None)
            client.generate_instances_sync(start, end, None, collect, None)
        except GLib.Error:
            continue
    now = time.time()
    events = [e for e in events if e["end"] > now]
    events.sort(key=lambda e: e["start"])
    return {"events": events[:8]}


# ── system ───────────────────────────────────────────────────────────────────

_cpu_prev = None


def _hwmon():
    temps = {}
    for d in glob.glob("/sys/class/hwmon/hwmon*"):
        name = read(f"{d}/name", "")
        want = {"k10temp": "CPU", "coretemp": "CPU", "amdgpu": "GPU", "nvme": "NVMe"}.get(name)
        if not want or want in temps:
            continue
        vals = [int(v) / 1000 for v in (read(p) for p in sorted(glob.glob(f"{d}/temp*_input"))) if v]
        if vals:
            temps[want] = round(max(vals) if want != "CPU" else vals[0], 1)
    return temps


def system(cfg):
    global _cpu_prev
    fields = [int(x) for x in read("/proc/stat").split("\n")[0].split()[1:]]
    idle, total = fields[3] + fields[4], sum(fields)
    cpu = 0.0
    if _cpu_prev and total > _cpu_prev[1]:
        cpu = 100 * (1 - (idle - _cpu_prev[0]) / (total - _cpu_prev[1]))
    _cpu_prev = (idle, total)
    mem = dict(line.split(":") for line in read("/proc/meminfo").split("\n"))
    kb = lambda k: int(mem[k].split()[0])
    gpu = None
    for p in glob.glob("/sys/class/drm/card*/device/gpu_busy_percent"):
        gpu = int(read(p, "0"))
        break
    return {"cpu": round(cpu, 1), "mem": round(100 * (1 - kb("MemAvailable") / kb("MemTotal")), 1),
            "memUsedGiB": round((kb("MemTotal") - kb("MemAvailable")) / 1048576, 1),
            "gpu": gpu, "temps": _hwmon(), "load": read("/proc/loadavg").split()[:3]}


# ── fleet + focus ────────────────────────────────────────────────────────────

def fleet(cfg):
    out = {}
    try:
        out["fleet"] = json.loads(run(["fleet-status"], 15))
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        out["fleetError"] = str(e)[:80]
    try:
        out["focus"] = json.loads(run(["focus", "status"], 8))
    except (OSError, ValueError, subprocess.SubprocessError):
        out["focus"] = None
    pomo = read(f"{RUN}/waybar-pomodoro")
    if pomo:
        out["pomodoro"] = dict(line.split("=", 1) for line in pomo.split("\n") if "=" in line)
    return out


# ── nix + storage ────────────────────────────────────────────────────────────

def nixhealth(cfg):
    link = os.readlink("/nix/var/nix/profiles/system")
    gen = link.split("-")[1] if link.startswith("system-") else link
    built = os.lstat(f"/nix/var/nix/profiles/{link}").st_mtime
    reboot = os.path.realpath("/run/booted-system/kernel") != os.path.realpath("/run/current-system/kernel")
    inputs = []
    lock = os.path.join(cfg["flakeDir"], "flake.lock")
    try:
        nodes = json.load(open(lock))["nodes"]
        root = nodes["root"]["inputs"]
        for name, ref in root.items():
            node = nodes.get(ref if isinstance(ref, str) else ref[-1], {})
            if "lastModified" in node.get("locked", {}):
                inputs.append({"name": name, "modified": node["locked"]["lastModified"]})
    except (OSError, ValueError, KeyError):
        pass
    inputs.sort(key=lambda i: i["modified"])
    st = os.statvfs("/nix/store")
    return {"generation": gen, "built": built, "rebootPending": reboot, "oldestInputs": inputs[:3],
            "storeFsUsedPct": round(100 * (1 - st.f_bavail / st.f_blocks), 1)}


def _smart():
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    res = bus.call_sync("org.freedesktop.UDisks2", "/org/freedesktop/UDisks2", "org.freedesktop.DBus.ObjectManager",
                        "GetManagedObjects", None, GLib.VariantType("(a{oa{sa{sv}}})"), 0, 5000, None).unpack()[0]
    out = []
    for ifaces in res.values():
        drive = ifaces.get("org.freedesktop.UDisks2.Drive")
        if not drive or drive.get("Removable"):
            continue
        ata = ifaces.get("org.freedesktop.UDisks2.Drive.Ata", {})
        nvme = ifaces.get("org.freedesktop.UDisks2.NVMe.Controller", {})
        bad = ata.get("SmartFailing") or bool(nvme.get("SmartCriticalWarning"))
        kelvin = ata.get("SmartTemperature") or nvme.get("SmartTemperature") or 0
        out.append({"model": drive.get("Model", "?"), "ok": not bad,
                    "temp": round(kelvin - 273.15) if kelvin else None,
                    "warnings": list(nvme.get("SmartCriticalWarning") or [])})
    return out


def backups(cfg):
    out = {"restic": None, "snapshot": None, "pools": [], "drives": []}
    prom = read(os.path.join(cfg["textfileDir"], "restic.prom"))
    if prom:
        out["restic"] = float(prom.split()[-1])
    snaps = glob.glob(os.path.join(cfg["snapDir"], "home.*"))
    if snaps:
        out["snapshot"] = max(os.lstat(p).st_mtime for p in snaps)
    seen = set()
    for line in read("/proc/mounts", "").split("\n"):
        dev, mnt, fstype = (line.split() + ["", "", ""])[:3]
        if not dev.startswith("/dev/") or fstype in ("squashfs", "vfat", "iso9660") or mnt.startswith(("/boot", "/nix/store")):
            continue
        try:
            st = os.statvfs(mnt)
        except OSError:
            continue
        # btrfs/bcachefs subvolumes report the whole pool, so keep one row per pool
        key = (st.f_blocks, st.f_frsize)
        if key in seen or not st.f_blocks:
            continue
        seen.add(key)
        size = st.f_blocks * st.f_frsize
        out["pools"].append({"mount": mnt, "fs": fstype, "sizeGiB": round(size / 2**30),
                             "usedPct": round(100 * (1 - st.f_bavail / st.f_blocks), 1)})
    try:
        out["drives"] = _smart()
    except Exception as e:  # udisks missing or denied: the card just hides drives
        out["drivesError"] = str(e)[:80]
    return out


# ── tariff ───────────────────────────────────────────────────────────────────

def _minutes(hhmm):
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)


def power(cfg):
    t = cfg["tariff"]
    now = dt.datetime.now()
    cur = now.hour * 60 + now.minute
    inside = lambda m: any((_minutes(w["start"]) <= m < _minutes(w["end"])) if _minutes(w["start"]) < _minutes(w["end"])
                           else (m >= _minutes(w["start"]) or m < _minutes(w["end"])) for w in t["windows"])
    off = inside(cur)
    step = 1
    while step < 1440 and inside((cur + step) % 1440) == off:
        step += 1
    return {"name": t["name"], "offPeak": off, "price": t["priceOffPeak"] if off else t["pricePeak"],
            "changeIn": step * 60 - now.second, "windows": t["windows"]}


PROVIDERS = {
    "weather": (weather, 900),
    "claude": (claude, 300),
    "gemini": (gemini, 600),
    "ci": (ci, 60),
    "github": (github, 300),
    "agenda": (agenda, 300),
    "system": (system, 2),
    "fleet": (fleet, 30),
    "nix": (nixhealth, 1800),
    "backups": (backups, 1800),
    "power": (power, 60),
}


# ── streams: long-running followers that push on change ──────────────────────

def _follow(cmd, parse, emit):
    while True:
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            for line in p.stdout:
                try:
                    emit(parse(line.rstrip("\n")))
                except (ValueError, IndexError):
                    pass
            p.wait()
        except OSError:
            pass
        emit(None)
        # player or swaync went away, retry quietly
        time.sleep(5)


def _media_line(line):
    status, player, artist, title, art, length = (line.split("\t") + [""] * 6)[:6]
    return {"status": status, "player": player, "artist": artist, "title": title,
            "art": urllib.parse.unquote(art[7:]) if art.startswith("file://") else art,
            "length": int(length) / 1e6 if length.isdigit() else None}


def follow_media(emit):
    fmt = "{{status}}\t{{playerName}}\t{{artist}}\t{{title}}\t{{mpris:artUrl}}\t{{mpris:length}}"
    _follow(["playerctl", "--follow", "metadata", "--format", fmt], _media_line, emit)


def follow_notifications(emit):
    _follow(["swaync-client", "--subscribe"], json.loads, emit)


STREAMS = {"media": follow_media, "notifications": follow_notifications}
