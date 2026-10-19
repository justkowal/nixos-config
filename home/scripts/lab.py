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


STATE = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "lab")


def merge(base, over):
    out = dict(base)
    for k, v in over.items():
        out[k] = merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def read_state(name):
    try:
        with open(os.path.join(STATE, name)) as f:
            return f.read().strip()
    except OSError:
        return ""


def write_state(name, text):
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, name), "w") as f:
        f.write(text)


def wallpaper():
    return read_state("wallpaper") or os.path.expanduser("~/Pictures/wallpaper.png")


def luminance(path):
    # 0 is black, 1 is white. Any failure counts as dark, the safe default for this desk.
    try:
        out = subprocess.run(
            ["magick", path, "-resize", "1x1!", "-colorspace", "Gray", "-format", "%[fx:mean]", "info:"],
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout
        return float(out)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0.0


def pick_mode(pack, path):
    if pack["mode"] != "auto":
        return pack["mode"]
    return "light" if luminance(path) > 0.6 else "dark"


def paint(pack, path):
    if not shutil.which("matugen"):
        return
    subprocess.run(
        ["matugen", "image", "--source-color-index", "0", "--mode", pick_mode(pack, path), "--type", pack["scheme"], path],
        check=False,
    )


def active_pack(themes):
    name = read_state("theme") or themes["default"]
    if name not in themes["packs"]:
        name = themes["default"]
    return name, themes["packs"][name]


def wait_for_bus(seconds=4):
    end = time.time() + seconds
    while time.time() < end:
        try:
            lab_bus.request({"op": "state"})
            return True
        except (OSError, ValueError):
            time.sleep(0.3)
    return False


def cmd_theme(a):
    themes = load_conf("themes.json")
    packs = themes["packs"]
    current, current_pack = active_pack(themes)
    if a.colors:
        paint(current_pack, a.colors)
        write_state("wallpaper", a.colors)
        return 0
    if a.next:
        names = sorted(packs)
        a.name = names[(names.index(current) + 1) % len(names)]
    if not a.name:
        for n in sorted(packs):
            print(f"{'*' if n == current else ' '} {n:<10} {packs[n]['title']} ({packs[n]['mode']}, {packs[n]['scheme']})")
        return 0
    if a.name not in packs:
        print(f"no theme pack '{a.name}', try: {', '.join(sorted(packs))}", file=sys.stderr)
        return 2
    pack = packs[a.name]
    base = load_conf("tokens.json")
    write_state("tokens.json", json.dumps(merge(base, pack["tokens"])))
    write_state("theme", a.name)
    paint(pack, wallpaper())
    # labd reads its tokens once at start, so a restart is the reload
    subprocess.run(["systemctl", "--user", "restart", "labd"], check=False)
    if wait_for_bus():
        emit("theme.changed", {"name": a.name, "title": pack["title"]}, source="theme")
    return 0


def cmd_clip(a):
    flag = os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "lab-clip-paused")
    paused = os.path.exists(flag)
    if a.action == "status":
        print("paused" if paused else "sharing")
        return 0
    if a.action == "toggle":
        a.action = "resume" if paused else "pause"
    if a.action == "pause":
        open(flag, "w").close()
    else:
        try:
            os.unlink(flag)
        except FileNotFoundError:
            pass
    emit("clipboard.paused" if a.action == "pause" else "clipboard.resumed", {}, source="continuity")
    return 0


def cmd_peek(a):
    # the preview window and the palette listing live in lab-peek, which needs the gi environment
    os.execvp("lab-peek", ["lab-peek", *a.rest])


def machine(target):
    """(hostname, short name) for `desktop` or `nixos-desktop` from continuity.json."""
    for host, name in load_conf("continuity.json")["names"].items():
        if target in (host, name):
            return host, name
    return None, None


def peer_ok(host, timeout=1.5):
    try:
        urllib.request.urlopen(f"http://{host}:8766/hello", timeout=timeout).read()
        return True
    except (OSError, ValueError):
        return False


def tailnet_up(host):
    r = subprocess.run([os.environ.get("TAILSCALE", "tailscale"), "ping", "-c", "1", "--timeout=1s", host], capture_output=True)
    return r.returncode == 0


def bring_online(host, name):
    """Wake the machine if it sleeps and wait until its session answers. The island shows a spinner,
    then a check when the machine is up, then a dot once it is online, and leaves after that."""
    if peer_ok(host):
        return True
    title = name.capitalize()

    def progress(state, **extra):
        emit("wake.progress", {"host": name, "title": title, "state": state, **extra}, "high", "wake", ttl=400)

    progress("waking")
    wake = load_conf("continuity.json").get("wake", {}).get(host)
    if wake:
        subprocess.Popen(wake, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 240
    while time.time() < deadline and not tailnet_up(host):
        time.sleep(1)
    if not tailnet_up(host):
        progress("failed", reason=f"{title} did not wake")
        return False
    progress("up")
    shown = time.time()
    # a booted machine with nobody logged in never answers, so say so early instead of spinning for minutes
    deadline = min(deadline, shown + 45)
    while time.time() < deadline and not peer_ok(host):
        time.sleep(1)
    if not peer_ok(host):
        progress("failed", reason=f"{title} is up, sign in there to continue")
        return False
    time.sleep(max(0.0, 0.9 - (time.time() - shown)))
    progress("online")
    return True


def peer_windows(host):
    try:
        return {w["addr"]: w for w in json.load(urllib.request.urlopen(f"http://{host}:8766/windows", timeout=3))}
    except (OSError, ValueError):
        return {}


def open_new_window(host, before, wait=20):
    """The app was started over there: show its window here as a Peek viewer, which moves it into portal mode."""
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(0.5)
        fresh = [w for a, w in peer_windows(host).items() if a not in before and w["workspace"] >= 0]
        if fresh:
            subprocess.Popen(["lab-peek", host, fresh[0]["addr"]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            return


def cmd_run(a):
    host, name = machine(a.target)
    if host is None:
        print(f"unknown machine '{a.target}'", file=sys.stderr)
        return 2
    if not bring_online(host, name):
        return 1
    if not a.app:
        return 0
    before = peer_windows(host)
    req = urllib.request.Request(f"http://{host}:8766/run", data=json.dumps({"app": a.app}).encode(), method="POST")
    try:
        urllib.request.urlopen(req, timeout=10).read()
        open_new_window(host, before)
    except urllib.error.HTTPError as e:
        why = "does not have that app" if e.code == 404 else f"refused it ({e.code})"
        emit("wake.progress", {"host": name, "title": name.capitalize(), "state": "failed", "reason": f"{name.capitalize()} {why}"}, "high", "wake", ttl=10)
        return 1
    except OSError:
        return 1
    return 0


def cmd_publish(a):
    # the compiled client owns the event contract and is fast enough for key repeat
    os.execvp("lab-publish", ["lab-publish", *a.rest])


def emit(name, payload, priority="normal", source="scene", ttl=None):
    # best effort: scenes still run with the shell down
    try:
        lab_bus.request({"op": "publish", "event": {"name": name, "source": source, "payload": payload, "priority": priority, **({"ttl": ttl} if ttl else {})}})
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
    p = sub.add_parser("theme", help="list theme packs, or switch to one")
    p.add_argument("name", nargs="?")
    p.add_argument("--next", action="store_true", help="switch to the next pack")
    p.add_argument("--colors", metavar="IMAGE", help="only regenerate Matugen colours for IMAGE with the active pack")
    p.set_defaults(fn=cmd_theme)
    p = sub.add_parser("run", help="wake another machine if needed and open an app on it: run desktop firefox.desktop")
    p.add_argument("target")
    p.add_argument("app", nargs="?", help="desktop file name, omit to only wake the machine")
    p.set_defaults(fn=cmd_run)
    p = sub.add_parser("clip", help="pause or resume clipboard sharing between your machines")
    p.add_argument("action", nargs="?", default="status", choices=["status", "toggle", "pause", "resume"])
    p.set_defaults(fn=cmd_clip)
    p = sub.add_parser("peek", help="preview a window on another machine: peek HOST ADDRESS | peek entries", add_help=False)
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_peek)
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
