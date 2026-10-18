#!/usr/bin/env python3
"""lab-inbox: receives rooms sent from your other machines over Taildrop.

Files land in the raw folder, are validated, and only then appear in the inbox that the palette
lists. Nothing is opened automatically: accepting a room is an explicit action in the palette.
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab_bus  # noqa: E402

TAILSCALE = os.environ.get("TAILSCALE", "tailscale")
STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "rooms"
MAX_BYTES = 256 * 1024
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


def validate(raw):
    """A room is {name?, from?, windows:[{class,...}]}. Anything else is dropped."""
    if len(raw) > MAX_BYTES:
        return None
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    wins = data.get("windows") if isinstance(data, dict) else None
    if not isinstance(wins, list) or not wins or not all(isinstance(w, dict) and isinstance(w.get("class"), str) for w in wins):
        return None
    return {"windows": wins, "from": str(data.get("from", "unknown"))[:64]}


MESSAGE_MAX = 16 * 1024
SEEN = []


def clean(s, limit):
    s = str(s)[:limit]
    return "".join(c for c in s if c == "\n" or c.isprintable())


def under_rate_limit(per_minute=30):
    now = time.time()
    SEEN[:] = [t for t in SEEN if now - t < 60]
    if len(SEEN) >= per_minute:
        return False
    SEEN.append(now)
    return True


def publish(name, payload, priority="normal", ttl=30):
    try:
        lab_bus.request({"op": "publish", "event": {"name": name, "source": "continuity", "priority": priority, "ttl": ttl, "payload": payload}})
    except (OSError, ValueError):
        pass


def handle_message(kind, raw):
    """notify-*.json and auth-*.json come from your own machines over Taildrop. Same caps as rooms."""
    if len(raw) > MESSAGE_MAX or not under_rate_limit():
        return False
    try:
        data = json.loads(raw)
    except ValueError:
        return False
    if not isinstance(data, dict):
        return False
    who = clean(data.get("from", "another machine"), 32)
    if kind == "notify":
        urgency = {0: "low", 1: "normal", 2: "critical"}.get(data.get("urgency"), "normal")
        app = clean(data.get("app", "App"), 48)
        summary = clean(data.get("summary", ""), 200) or app
        # the hint keeps the sender from mirroring it straight back
        subprocess.run(["notify-send", "-a", f"{app} on {who}", "-u", urgency, "-h", "string:x-lab-mirror:1", "--", summary, clean(data.get("body", ""), 1000)], check=False)
        return True
    if kind == "auth":
        if data.get("state") == "done":
            publish("auth.done", {"ok": data.get("ok") is True, "host": who}, "high", 20)
        else:
            publish("auth.waiting", {"app": clean(data.get("app", "An app"), 48), "host": who}, "high", 20)
        return True
    return False


def process(landing, inbox):
    inbox.mkdir(parents=True, exist_ok=True)
    for f in sorted(landing.iterdir()):
        name = f.name[:-5] if f.name.endswith(".json") else f.name
        kind = name.split("-", 1)[0]
        if kind in ("notify", "auth") and "-" in name:
            try:
                ok = handle_message(kind, f.read_bytes())
            except OSError:
                ok = False
            f.unlink(missing_ok=True)
            if not ok:
                print(f"lab-inbox: dropped {f.name!r}", file=sys.stderr, flush=True)
            continue
        try:
            room = validate(f.read_bytes()) if NAME_RE.fullmatch(name) else None
        except OSError:
            room = None
        f.unlink(missing_ok=True)
        if room is None:
            print(f"lab-inbox: dropped {f.name!r}", file=sys.stderr, flush=True)
            continue
        (inbox / f"{name}.json").write_text(json.dumps({"name": name, **room}, indent=2))
        try:
            lab_bus.request({"op": "publish", "event": {"name": "room.received", "source": "room", "priority": "high",
                                                         "payload": {"name": name, "from": room["from"], "windows": len(room["windows"])}}})
        except (OSError, ValueError):
            pass


def main():
    landing, inbox = STATE / "inbox-raw", STATE / "inbox"
    landing.mkdir(parents=True, exist_ok=True)
    while True:
        # --wait blocks until something arrives, moves it into landing, then exits
        res = subprocess.run([TAILSCALE, "file", "get", "--wait", "--conflict=rename", str(landing)], capture_output=True, text=True)
        if res.returncode != 0:
            print(f"lab-inbox: {res.stderr.strip()[:200]}", file=sys.stderr, flush=True)
            time.sleep(30)
            continue
        process(landing, inbox)


if __name__ == "__main__":
    main()
