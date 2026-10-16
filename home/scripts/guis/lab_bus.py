"""Kowal Lab state bus client: newline-delimited JSON over a unix socket.

The server is labd (pkgs/labd/src/bus.rs). This module is the client side for the lab CLI and
Python providers, and mirrors the event contract. Stdlib only.
"""

import json
import os
import re
import socket
import time

PRIORITIES = ("low", "normal", "high")
NAME_RE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")


def sock_path():
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "lab.sock")


def make_event(name, source, payload=None, priority="normal", ttl=30):
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise ValueError(f"event name must be dotted lowercase (focus.on), got {name!r}")
    if not isinstance(source, str) or not source:
        raise ValueError("event source is required")
    if payload is None:
        payload = {}
    if not isinstance(payload, dict):
        raise ValueError("event payload must be a JSON object")
    if priority not in PRIORITIES:
        raise ValueError(f"priority must be one of {PRIORITIES}")
    if not isinstance(ttl, (int, float)) or isinstance(ttl, bool) or ttl <= 0:
        raise ValueError("ttl must be a positive number of seconds")
    return {"name": name, "source": source, "payload": payload, "priority": priority, "ttl": ttl, "ts": time.time()}


def request(msg, timeout=2.0):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(sock_path())
        s.sendall((json.dumps(msg) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    reply = json.loads(buf)
    if not reply.get("ok"):
        raise ValueError(reply.get("error", "bus error"))
    return reply


def watch():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path())
    s.sendall(b'{"op": "subscribe"}\n')
    with s.makefile("r") as f:
        f.readline()
        for line in f:
            yield json.loads(line)
