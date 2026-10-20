"""Fleet MCP: roster, wake over the Pi webhook, and a fixed verb set over forced-command ssh."""
import base64
import json
import os
import socket
import subprocess
import urllib.request

from stdio_mcp import obj, serve

HOSTS = json.loads(os.environ.get("FLEET_HOSTS", "{}"))
WAKE_URL = os.environ.get("FLEET_WAKE_URL", "")
KEY = "/tmp/fleet_key"
VERBS = {"status", "poweroff", "reboot", "suspend", "update-stage", "update-deploy"}


def host(a):
    h = a.get("host")
    if h not in HOSTS:
        raise RuntimeError(f"host must be one of {sorted(HOSTS)}")
    return HOSTS[h]


def key_file():
    if not os.path.exists(KEY):
        b64 = os.environ.get("FLEET_SSH_KEY_B64", "")
        if not b64:
            raise RuntimeError("FLEET_SSH_KEY_B64 is not configured")
        fd = os.open(KEY, os.O_WRONLY | os.O_CREAT, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(base64.b64decode(b64).decode().rstrip("\n") + "\n")
    return KEY


def agent(h, verb):
    if verb not in VERBS:
        raise RuntimeError("verb not allowed")
    r = subprocess.run(
        ["ssh", "-i", key_file(), "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
         "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=/tmp/known_hosts",
         f"fleet-agent@{h['ip']}", verb],
        capture_output=True, text=True, timeout=30)
    out = (r.stdout + r.stderr).strip()
    if r.returncode not in (0, 255) or (r.returncode == 255 and verb in ("poweroff", "reboot", "suspend")):
        return out or f"{verb} requested"  # connection drops as the host goes down
    if r.returncode == 255:
        raise RuntimeError(out or "ssh failed, is the host awake?")
    return out or f"{verb} ok"


def online(ip):
    try:
        socket.create_connection((ip, 22), timeout=2).close()
        return True
    except OSError:
        return False


def roster(_a):
    return [{"host": n, "ip": h["ip"], "online": online(h["ip"]), "can_wake": bool(h.get("wake"))}
            for n, h in HOSTS.items()]


def wake(a):
    h = host(a)
    if not h.get("wake") or not WAKE_URL:
        raise RuntimeError("this host has no wake hook")
    with urllib.request.urlopen(urllib.request.Request(f"{WAKE_URL}/{h['wake']}", method="POST"), timeout=10) as r:
        return f"wake signal sent ({r.status})"


def power(a):
    act = a.get("action")
    if act not in ("suspend", "reboot", "poweroff"):
        raise RuntimeError("action must be suspend, reboot or poweroff")
    return agent(host(a), act)


def update(a):
    mode = a.get("mode")
    if mode not in ("stage", "deploy"):
        raise RuntimeError("mode must be stage or deploy")
    return agent(host(a), f"update-{mode}")


names = sorted(HOSTS) or ["<host>"]
H = {"host": {"type": "string", "enum": names}}
serve("fleet", {
    "fleet_roster": dict(desc="Fleet hosts with reachability (TCP 22) and whether they can be woken.",
                         schema=obj(), fn=roster, ro=True),
    "fleet_status": dict(desc="Uptime and failed unit count of a host (it must be awake).",
                         schema=obj(H, ["host"]), fn=lambda a: agent(host(a), "status"), ro=True),
    "fleet_wake": dict(desc="Send a Wake-on-LAN signal to a host through the Pi.",
                       schema=obj(H, ["host"]), fn=wake),
    "fleet_update": dict(desc="Start a NixOS update on a host: stage (pre-build) or deploy (switch).",
                         schema=obj({**H, "mode": {"type": "string", "enum": ["stage", "deploy"]}}, ["host", "mode"]),
                         fn=update, sensitive=True),
    "fleet_power": dict(desc="Suspend, reboot or power off a host. Ends the user's session there.",
                        schema=obj({**H, "action": {"type": "string", "enum": ["suspend", "reboot", "poweroff"]}},
                                   ["host", "action"]), fn=power, sensitive=True),
})
