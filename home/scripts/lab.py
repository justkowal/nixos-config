#!/usr/bin/env python3
"""lab: publish to and inspect the Kowal Lab state bus."""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

import lab_bus

CONF = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "lab")


def load_conf(name):
    with open(os.path.join(CONF, name)) as f:
        return json.load(f)


def cmd_publish(a):
    # the compiled client owns the event contract and is fast enough for key repeat
    os.execvp("lab-publish", ["lab-publish", *a.rest])


def cmd_status(a):
    state = lab_bus.request({"op": "state"})["state"]
    if a.json:
        json.dump(state, sys.stdout, indent=2)
        print()
        return 0
    now = time.time()
    for name, ev in sorted(state.items()):
        age = now - ev["ts"]
        flag = "stale" if age > ev["ttl"] else "live"
        print(f"{name:<28} {ev['source']:<12} {age:>6.0f}s  {flag:<5} {json.dumps(ev['payload'])}")
    return 0


def cmd_watch(_a):
    try:
        for ev in lab_bus.watch():
            print(json.dumps(ev), flush=True)
    except KeyboardInterrupt:
        pass
    return 0


def cmd_keys(_a):
    try:
        entries = load_conf("keymap.json")
    except OSError as e:
        print(f"lab: no keymap ({e}), has the home config been switched?", file=sys.stderr)
        return 1
    group = None
    for e in sorted(entries, key=lambda e: (e["group"], e["label"])):
        if e["group"] != group:
            group = e["group"]
            print(f"\n{group}")
        combo = " + ".join(p for p in [*e["mods"].split(), e["key"]] if p).replace("$mod", "SUPER")
        print(f"  {combo:<24} {e['label']}")
    return 0


def check(label, fn):
    try:
        detail = fn()
        print(f"ok    {label}" + (f" ({detail})" if detail else ""))
        return True
    except Exception as e:  # a failing check is a result, never a crash
        print(f"FAIL  {label}: {e}")
        return False


def chk_bus():
    return f"{len(lab_bus.request({'op': 'state'})['state'])} events"


def chk_shell():
    for unit in ("labd", "deskwidgets"):
        out = subprocess.run(["systemctl", "--user", "is-active", unit], capture_output=True, text=True).stdout.strip()
        if out != "active":
            raise RuntimeError(f"{unit} is {out or 'unknown'}")


def chk_tokens():
    t = load_conf("tokens.json")
    missing = [k for k in ("type", "radius", "motion", "material") if k not in t]
    if missing:
        raise RuntimeError(f"missing {missing}")


def chk_keymap():
    seen = set()
    for e in load_conf("keymap.json"):
        k = (e["mods"], e["key"])
        if k in seen:
            raise RuntimeError(f"duplicate bind {k}")
        seen.add(k)
    return f"{len(seen)} binds"


def chk_fallbacks():
    gone = [b for b in ("waybar", "swaync") if not shutil.which(b)]
    if gone:
        raise RuntimeError(f"fallback missing: {', '.join(gone)}")


def chk_sound():
    if not shutil.which("canberra-gtk-play"):
        raise RuntimeError("canberra-gtk-play not on PATH")


def cmd_doctor(_a):
    results = [check(label, fn) for label, fn in (
        ("bus", chk_bus), ("shell services", chk_shell), ("tokens", chk_tokens),
        ("keymap", chk_keymap), ("waybar and swaync fallbacks", chk_fallbacks), ("sound", chk_sound))]
    return 0 if all(results) else 1


def main():
    ap = argparse.ArgumentParser(prog="lab")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("publish", help="publish an event (see lab-publish)", add_help=False)
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_publish)
    p = sub.add_parser("status", help="last event per name")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_status)
    sub.add_parser("watch", help="stream events").set_defaults(fn=cmd_watch)
    sub.add_parser("keys", help="print the keymap").set_defaults(fn=cmd_keys)
    sub.add_parser("doctor", help="check every Lab component").set_defaults(fn=cmd_doctor)
    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
