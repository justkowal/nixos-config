#!/usr/bin/env python3
"""lab-roster: publishes which of your devices are reachable, read from tailscale status.

roster.changed {devices:[{host,title,kind,os,online,self}]} on change and every few minutes,
roster.device {title,online} when a device comes or goes.
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab_bus  # noqa: E402

TAILSCALE = os.environ.get("TAILSCALE", "tailscale")
INTERVAL = 15
REPUBLISH = 240


def short(node):
    """The dns label (nixos-desktop) is stable, HostName is not (Nothing Phone (2a))."""
    return (node.get("DNSName") or node.get("HostName", "")).split(".")[0].lower()


def devices_from_status(status, names):
    me = status["Self"]
    nodes = [(me, True)] + [(n, False) for n in status.get("Peer", {}).values() if n.get("UserID") == me.get("UserID")]
    out = []
    for node, is_self in nodes:
        host = short(node)
        meta = names.get(host, {})
        out.append({"host": host, "title": meta.get("title", node.get("HostName", host)), "kind": meta.get("kind", "device"),
                    "os": node.get("OS", ""), "online": bool(is_self or node.get("Online")), "self": is_self})
    out.sort(key=lambda d: (not d["self"], d["title"].lower()))
    return out


def emit(name, payload, ttl=300):
    try:
        lab_bus.request({"op": "publish", "event": {"name": name, "source": "roster", "payload": payload, "ttl": ttl}})
    except (OSError, ValueError):
        pass


def snapshot():
    out = subprocess.run([TAILSCALE, "status", "--json"], capture_output=True, text=True, timeout=10, check=True).stdout
    return json.loads(out)


def main(names_path):
    with open(names_path) as f:
        names = json.load(f)
    last, sent = None, 0.0
    while True:
        try:
            devices = devices_from_status(snapshot(), names)
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
            print(f"lab-roster: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
            time.sleep(INTERVAL)
            continue
        state = {d["host"]: d["online"] for d in devices}
        if last is not None:
            for d in devices:
                if d["host"] in last and last[d["host"]] != d["online"] and not d["self"]:
                    emit("roster.device", {"title": d["title"], "online": d["online"]}, 30)
        if state != last or time.time() - sent > REPUBLISH:
            emit("roster.changed", {"devices": devices})
            sent = time.time()
        last = state
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main(sys.argv[1])
