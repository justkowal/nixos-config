#!/usr/bin/env python3
"""Alertmanager-compatible sink for vmalert that forwards state changes to ntfy."""

import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

NTFY_URL = os.environ.get("NTFY_URL", "https://ntfy.lab/alerts")
LISTEN = os.environ.get("LISTEN_PORT", "9094")

# vmalert resends firing alerts every evaluation, so only transitions get forwarded
firing: set[str] = set()

_TS = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)$")


def parse_ts(s: str) -> datetime | None:
    m = _TS.match(s or "")
    if not m:
        return None
    tz = "+00:00" if m.group(2) == "Z" else m.group(2)
    return datetime.fromisoformat(m.group(1) + tz)


def notify(title: str, body: str, priority: str, tags: str) -> None:
    req = urllib.request.Request(
        NTFY_URL,
        data=body.encode(),
        headers={"Title": title, "Priority": priority, "Tags": tags},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10).close()
    except Exception as e:
        print(f"ntfy post failed: {e}", file=sys.stderr, flush=True)


def handle(alerts: list[dict]) -> None:
    now = datetime.now(timezone.utc)
    for a in alerts:
        labels = a.get("labels", {})
        key = json.dumps(labels, sort_keys=True)
        ends = parse_ts(a.get("endsAt", ""))
        resolved = ends is not None and ends <= now
        name = labels.get("alertname", "alert")
        where = labels.get("instance") or labels.get("host") or ""
        ann = a.get("annotations", {})
        body = ann.get("summary") or ann.get("description") or name
        if resolved and key in firing:
            firing.discard(key)
            notify(f"RESOLVED {name} {where}".strip(), body, "low", "white_check_mark")
        elif not resolved and key not in firing:
            firing.add(key)
            notify(f"{name} {where}".strip(), body, "high", "warning")


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
            alerts = json.loads(self.rfile.read(n) or b"[]")
            if isinstance(alerts, list):
                handle(alerts)
            self.send_response(200)
        except Exception as e:
            print(f"bad request: {e}", file=sys.stderr, flush=True)
            self.send_response(400)
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(LISTEN)), Handler).serve_forever()
