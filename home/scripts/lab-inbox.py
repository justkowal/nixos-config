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


def process(landing, inbox):
    inbox.mkdir(parents=True, exist_ok=True)
    for f in sorted(landing.iterdir()):
        name = f.name[:-5] if f.name.endswith(".json") else f.name
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
