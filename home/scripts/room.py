#!/usr/bin/env python3
"""room: save and reopen Hyprland workspace layouts per project.

  room save <name> [--all]     current workspace (or every regular workspace)
  room open <name> [--dry-run]
  room pick                    rofi list of saved rooms plus git repos under ~
  room list
  room entries                 JSON for the command palette: inbox, saved rooms, repos, send actions
  room send <name> [peer]      send a saved room to your other machine over Taildrop
  room accept <name>           move a received room from the inbox into saved rooms
"""

import json
import os
import shlex
import socket
import shutil
import subprocess
import sys
from pathlib import Path

STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "rooms"
INBOX = STATE / "inbox"
PEER = os.environ.get("ROOM_PEER", "")
PEER_TITLE = os.environ.get("ROOM_PEER_TITLE", PEER)
TAILSCALE = os.environ.get("TAILSCALE", "tailscale")
TERMINALS = {"kitty", "foot", "alacritty", "org.wezfurlong.wezterm", "com.mitchellh.ghostty"}
BROWSERS = {"firefox"}
# windows that belong to the desktop shell, not to a project
IGNORE = {"scratchpad", "waybar", "swaync", "rofi"}


def hypr(*args):
    out = subprocess.run(["hyprctl", *args, "-j"], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def children(pid):
    kids = []
    for task in Path(f"/proc/{pid}/task").glob("*/children"):
        try:
            kids += [int(p) for p in task.read_text().split()]
        except OSError:
            pass
    return kids


def proc_cwd(pid):
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return None


def proc_argv(pid):
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return []
    return [a.decode(errors="replace") for a in raw.split(b"\0") if a]


def relaunchable(argv, klass):
    """Map /nix/store/...-wrapped argv[0] back to a PATH command so a GC does not break the room."""
    if not argv:
        return [klass.lower()]
    name = os.path.basename(argv[0])
    if name.startswith(".") and name.endswith("-wrapped"):
        name = name[1:-len("-wrapped")]
    if shutil.which(name):
        return [name, *argv[1:]]
    if os.path.exists(argv[0]):
        return argv
    return [klass.lower()]


def publish(event, payload):
    # the island may be down, rooms must work without it
    try:
        subprocess.run(["lab", "publish", event, "--source", "room", "--payload", json.dumps(payload)],
                       check=False, capture_output=True)
    except OSError:
        pass


def save(name, all_ws):
    if all_ws:
        wanted = {w["id"] for w in hypr("workspaces") if w["id"] > 0}
    else:
        wanted = {hypr("activeworkspace")["id"]}
    windows = []
    for c in hypr("clients"):
        ws = c["workspace"]["id"]
        klass = c.get("initialClass") or c.get("class") or ""
        if ws not in wanted or not klass or klass.lower() in IGNORE:
            continue
        win = {
            "class": klass,
            "title": c.get("title", ""),
            "workspace": ws,
            "floating": c.get("floating", False),
            "size": c.get("size"),
            "at": c.get("at"),
        }
        if klass.lower() in TERMINALS:
            kids = children(c["pid"])
            # first child is the shell kitty/foot spawned for this window
            win["cwd"] = proc_cwd(kids[0]) if kids else proc_cwd(c["pid"])
        elif klass.lower() not in BROWSERS:
            win["cmd"] = relaunchable(proc_argv(c["pid"]), klass)
        windows.append(win)
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / f"{name}.json").write_text(json.dumps({"name": name, "windows": windows}, indent=2))
    print(f"saved {len(windows)} windows to {STATE / f'{name}.json'}")
    publish("room.saved", {"name": name, "windows": len(windows)})


def desktop_programs():
    """Program names of installed desktop applications: the only ones a received room may relaunch."""
    dirs = [Path.home() / ".local/share"] + [Path(d) for d in os.environ.get("XDG_DATA_DIRS", "/usr/share").split(":") if d]
    names = set()
    for d in dirs:
        for f in (d / "applications").glob("*.desktop"):
            try:
                for line in f.read_text(errors="ignore").splitlines():
                    if line.startswith("Exec="):
                        argv = shlex.split(line[5:])
                        # skip `env VAR=1 prog` style prefixes
                        argv = [a for a in argv if "=" not in a.split("/")[-1] or a.startswith("/")]
                        if argv and argv[0] == "env":
                            argv = argv[1:]
                        if argv:
                            names.add(os.path.basename(argv[0]))
                        break
            except (OSError, ValueError):
                continue
    return names


def sanitize_foreign(windows):
    """A room from another machine only gets to relaunch programs by name, never run its own arguments."""
    out = []
    apps = desktop_programs()
    for w in windows:
        klass = str(w.get("class", ""))
        if not klass:
            continue
        clean = {"class": klass, "title": str(w.get("title", ""))[:200], "workspace": w.get("workspace") if isinstance(w.get("workspace"), int) else None}
        try:
            size, at = [int(v) for v in w["size"]], [int(v) for v in w["at"]]
            if w.get("floating") and len(size) == 2 and len(at) == 2:
                clean.update(floating=True, size=size, at=at)
        except (KeyError, TypeError, ValueError):
            pass
        k = klass.lower()
        if k in TERMINALS:
            cwd = w.get("cwd")
            clean["cwd"] = cwd if isinstance(cwd, str) else None
        elif k not in BROWSERS:
            cmd = w.get("cmd")
            prog = os.path.basename(cmd[0]) if isinstance(cmd, list) and cmd and isinstance(cmd[0], str) else k
            if prog not in apps or not shutil.which(prog):
                continue
            clean["cmd"] = [prog]
        out.append(clean)
    return out


def send(name, peer):
    path = STATE / f"{name}.json"
    if not path.exists():
        sys.exit(f"no saved room '{name}' to send")
    if not peer:
        sys.exit("no peer: pass one or set lab.rooms.peer")
    import tempfile

    room = json.loads(path.read_text())
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / f"{name}.json"
        out.write_text(json.dumps({"name": name, "from": socket.gethostname(), "windows": room["windows"]}))
        res = subprocess.run([TAILSCALE, "file", "cp", str(out), f"{peer}:"], capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"send failed: {res.stderr.strip()[:200]}")
    print(f"sent {name} to {peer}")
    publish("room.sent", {"name": name, "peer": PEER_TITLE or peer})


def accept(name):
    src = INBOX / f"{name}.json"
    if not src.exists():
        sys.exit(f"no received room '{name}'")
    room = json.loads(src.read_text())
    dest = STATE / f"{name}.json"
    if dest.exists():
        dest = STATE / f"{name}-from-{room.get('from', 'peer')}.json"
    STATE.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps({"name": dest.stem, "windows": sanitize_foreign(room["windows"])}, indent=2))
    src.unlink()
    print(dest.stem)
    publish("room.accepted", {"name": dest.stem})
    return dest.stem


def entries():
    q = shlex.quote
    found = []
    if INBOX.is_dir():
        for f in sorted(INBOX.glob("*.json")):
            try:
                room = json.loads(f.read_text())
            except (OSError, ValueError):
                continue
            found.append({"title": f"{f.stem} from {room.get('from', 'peer')}", "group": "Inbox", "rank": 0,
                          "exec": f"room take {q(f.stem)}"})
    rooms = saved()
    found += [{"title": r, "group": "Room", "rank": 1, "exec": f"room open {q(r)}"} for r in rooms]
    found += [{"title": n, "group": "Repo", "rank": 1, "exec": f"room open {q(n)}"} for n in sorted(repos()) if n not in rooms]
    if PEER:
        found += [{"title": f"Send {r} to {PEER_TITLE}", "group": "Send", "rank": 2, "exec": f"room send {q(r)}"} for r in rooms]
    return found


def terminal_cmd(klass, cwd):
    k = klass.lower()
    if k == "foot":
        return ["foot", "--working-directory", cwd]
    if k == "alacritty":
        return ["alacritty", "--working-directory", cwd]
    if k == "org.wezfurlong.wezterm":
        return ["wezterm", "start", "--cwd", cwd]
    if k == "com.mitchellh.ghostty":
        return ["ghostty", f"--working-directory={cwd}"]
    return ["kitty", "--directory", cwd]


def launch_cmd(name, win):
    k = win["class"].lower()
    if k in TERMINALS:
        cwd = win.get("cwd") or str(Path.home())
        # direnv (nix-direnv) in the shell picks up the project's dev shell on its own
        return terminal_cmd(win["class"], cwd if os.path.isdir(cwd) else str(Path.home()))
    if k in BROWSERS:
        profile = STATE / name / "firefox"
        profile.mkdir(parents=True, exist_ok=True)
        return ["firefox", "--profile", str(profile)]
    return win.get("cmd") or [k]


def rules(win, ws):
    r = [f"workspace {ws} silent"]
    if win.get("floating") and win.get("size") and win.get("at"):
        w, h = win["size"]
        x, y = win["at"]
        r += ["float 1", f"size {w} {h}", f"move {x} {y}"]
    return "; ".join(r)


def open_room(name, dry_run=False):
    path = STATE / f"{name}.json"
    if path.exists():
        room = json.loads(path.read_text())
        windows = room["windows"]
    else:
        repo = repos().get(name)
        if not repo:
            sys.exit(f"no room '{name}' and no git repo with that name under ~")
        windows = [{"class": "kitty", "cwd": repo, "workspace": None}]
    # saved workspace numbers may now hold other stuff; remap them onto free ones in order
    used = {w["id"] for w in hypr("workspaces") if w["windows"] > 0}
    free = (i for i in range(1, 100) if i not in used)
    remap = {}
    for win in windows:
        old = win.get("workspace")
        if old not in remap:
            remap[old] = next(free)
        cmd = f"[{rules(win, remap[old])}] {shlex.join(launch_cmd(name, win))}"
        if dry_run:
            print(cmd)
        else:
            subprocess.run(["hyprctl", "dispatch", "exec", cmd], check=False, capture_output=True)
    if not dry_run and remap:
        subprocess.run(["hyprctl", "dispatch", "workspace", str(min(remap.values()))], check=False, capture_output=True)
    if not dry_run:
        publish("room.restored", {"name": name, "windows": len(windows)})


def repos():
    home = Path.home()
    found = {}
    for git in [*home.glob("*/.git"), *home.glob("*/*/.git")]:
        repo = git.parent
        if any(part.startswith(".") for part in repo.relative_to(home).parts):
            continue
        found.setdefault(repo.name, str(repo))
    return found


def saved():
    return sorted(p.stem for p in STATE.glob("*.json")) if STATE.exists() else []


def pick():
    rooms = saved()
    lines = [f"room  {r}" for r in rooms]
    lines += [f"repo  {n}  ({p.replace(str(Path.home()), '~')})" for n, p in sorted(repos().items()) if n not in rooms]
    res = subprocess.run(["rofi", "-dmenu", "-i", "-p", "Room"], input="\n".join(lines), capture_output=True, text=True)
    choice = res.stdout.strip()
    if not choice:
        return
    open_room(choice.split()[1])


def main(argv):
    if len(argv) < 2 or argv[1] in {"-h", "--help"}:
        print(__doc__.strip())
        return
    cmd, rest = argv[1], argv[2:]
    if cmd == "save" and rest:
        save(rest[0], "--all" in rest)
    elif cmd == "open" and rest:
        open_room(rest[0], "--dry-run" in rest)
    elif cmd == "pick":
        pick()
    elif cmd == "list":
        print("\n".join(saved()))
    elif cmd == "entries":
        print(json.dumps(entries()))
    elif cmd == "send" and rest:
        send(rest[0], rest[1] if len(rest) > 1 else PEER)
    elif cmd == "accept" and rest:
        accept(rest[0])
    else:
        sys.exit(__doc__.strip())


if __name__ == "__main__":
    main(sys.argv)
