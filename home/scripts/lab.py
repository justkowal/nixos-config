#!/usr/bin/env python3
"""lab: publish to and inspect the Kowal Lab state bus."""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

import lab_bus

CONF = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "lab")


def load_conf(name):
    with open(os.path.join(CONF, name)) as f:
        return json.load(f)


def cmd_publish(a):
    # the compiled client owns the event contract and is fast enough for key repeat
    os.execvp("lab-publish", ["lab-publish", *a.rest])


def emit(name, payload, priority="normal"):
    # best effort: scenes still run with the shell down
    try:
        lab_bus.request({"op": "publish", "event": {"name": name, "source": "scene", "payload": payload, "priority": priority}})
    except (OSError, ValueError):
        pass


def cmd_scene(a):
    scenes = load_conf("scenes.json")
    if not a.name:
        for name, sc in sorted(scenes.items()):
            print(f"{name:<12} {sc['title']}  ({len(sc['steps'])} steps)")
        return 0
    sc = scenes.get(a.name)
    if sc is None:
        print(f"lab: no scene {a.name!r}, have: {', '.join(sorted(scenes))}", file=sys.stderr)
        return 2
    emit("scene.started", {"name": a.name, "title": sc["title"]}, "low")
    failed = 0
    for step in sc["steps"]:
        if subprocess.run(step, shell=True).returncode != 0:
            failed += 1
            print(f"lab: scene {a.name}: step failed: {step}", file=sys.stderr)
    emit("scene.done", {"name": a.name, "title": sc["title"], "announce": sc.get("announce", True), "failed": failed}, "high" if failed else "normal")
    return 1 if failed else 0


def cmd_phone(a):
    """URL and token for the phone app. The token is a secret: it is printed here or copied, never published."""
    try:
        cfg = load_conf("phone.json")
    except OSError:
        print("lab: the phone app is off, set lab.phone.enable = true and switch", file=sys.stderr)
        return 1
    token_file = os.path.join(CONF, "phone-token")
    try:
        with open(token_file) as f:
            token = f.read().strip()
    except OSError:
        print("lab: no token yet, labd creates it on its first start with the phone app enabled", file=sys.stderr)
        return 1
    host = ""
    try:
        status = json.loads(subprocess.run([os.environ.get("TAILSCALE", "tailscale"), "status", "--json"],
                                           capture_output=True, text=True, timeout=10).stdout)
        host = status["Self"]["DNSName"].rstrip(".")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        pass
    url = f"http://{host or 'this-machine'}:{cfg.get('port', 8765)}"
    if a.copy:
        if not shutil.which("wl-copy"):
            print("lab: wl-copy is not installed", file=sys.stderr)
            return 1
        subprocess.run(["wl-copy"], input=token, text=True)
        if shutil.which("notify-send"):
            subprocess.run(["notify-send", "-a", "Kowal Lab", "Phone app", f"Token copied. Open {url} on the phone and paste it."])
        return 0
    print(f"URL    {url}\nToken  {token}")
    return 0


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


def chk_continuity():
    bad = []
    for unit in ("lab-roster", "lab-inbox"):
        out = subprocess.run(["systemctl", "--user", "is-active", unit], capture_output=True, text=True).stdout.strip()
        if out != "active":
            bad.append(f"{unit} is {out or 'unknown'}")
    if bad:
        raise RuntimeError(", ".join(bad) + " (inbox needs tailscale --operator for your user)")


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


def chk_hub():
    """Focus mode lives on the hub: its webhook has to know the focus hooks, or `focus` cannot start."""
    base = os.environ.get("LAB_HUB_HOOKS")
    if not base:
        return "not configured here"
    try:
        with urllib.request.urlopen(base.rstrip("/") + "/focus-status", timeout=4) as r:
            json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise RuntimeError("the hub has no focus hooks, deploy nixos-rpi4 (docs/DEPLOYMENT.md)") from e
        raise RuntimeError(f"the hub answered {e.code}") from e
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise RuntimeError(f"the hub is unreachable ({getattr(e, 'reason', e)})") from e
    return "focus hooks answer"


def chk_tailnet():
    out = subprocess.run([os.environ.get("TAILSCALE", "tailscale"), "status", "--json"],
                         capture_output=True, text=True, timeout=10).stdout
    st = json.loads(out)
    if st.get("BackendState") != "Running":
        raise RuntimeError(f"tailscale is {st.get('BackendState', 'unknown')}")
    online = sum(1 for p in st.get("Peer", {}).values() if p.get("Online"))
    return f"{online} other devices online"


def chk_sound():
    if not shutil.which("canberra-gtk-play"):
        raise RuntimeError("canberra-gtk-play not on PATH")


def cmd_doctor(_a):
    results = [check(label, fn) for label, fn in (
        ("bus", chk_bus), ("tailnet", chk_tailnet), ("hub focus hooks", chk_hub), ("shell services", chk_shell), ("continuity services", chk_continuity), ("tokens", chk_tokens),
        ("keymap", chk_keymap), ("waybar and swaync fallbacks", chk_fallbacks), ("sound", chk_sound))]
    return 0 if all(results) else 1


def main():
    ap = argparse.ArgumentParser(prog="lab")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("publish", help="publish an event (see lab-publish)", add_help=False)
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_publish)
    p = sub.add_parser("scene", help="run a scene, or list them")
    p.add_argument("name", nargs="?")
    p.set_defaults(fn=cmd_scene)
    p = sub.add_parser("phone", help="URL and token for the phone app")
    p.add_argument("--copy", action="store_true", help="copy the token to the clipboard instead of printing it")
    p.set_defaults(fn=cmd_phone)
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
