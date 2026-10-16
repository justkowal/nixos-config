"""Kowal Lab state bus: newline-delimited JSON over a unix socket.

Shared by the shell (server) and the lab CLI (client). Stdlib only.
"""

import json
import os
import re
import socket
import socketserver
import threading
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


# ── server ───────────────────────────────────────────────────────────────────

class Bus:
    """Keeps the last event per name and fans new ones out to subscribers."""

    def __init__(self, on_event=None):
        self.state = {}
        self.subs = set()
        self.lock = threading.Lock()
        self.on_event = on_event
        self.server = None

    def publish(self, ev):
        with self.lock:
            self.state[ev["name"]] = ev
            dead = []
            line = (json.dumps(ev) + "\n").encode()
            for conn in self.subs:
                try:
                    conn.sendall(line)
                except OSError:
                    dead.append(conn)
            self.subs.difference_update(dead)
        if self.on_event:
            self.on_event(ev)

    def snapshot(self):
        with self.lock:
            return dict(self.state)

    def start(self):
        path = sock_path()
        if os.path.exists(path):
            try:
                request({"op": "state"}, timeout=0.5)
                raise OSError(f"another bus is already serving {path}")
            except (ConnectionRefusedError, FileNotFoundError, socket.timeout):
                os.unlink(path)
        bus = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                for raw in self.rfile:
                    try:
                        reply = bus.dispatch(json.loads(raw), self.request)
                    except (ValueError, KeyError) as e:
                        reply = {"ok": False, "error": str(e)}
                    if reply is not None:
                        self.request.sendall((json.dumps(reply) + "\n").encode())

            def finish(self):
                with bus.lock:
                    bus.subs.discard(self.request)
                super().finish()

        class Server(socketserver.ThreadingUnixStreamServer):
            daemon_threads = True

        self.server = Server(path, Handler)
        os.chmod(path, 0o600)
        threading.Thread(target=self.server.serve_forever, daemon=True, name="lab-bus").start()

    def dispatch(self, msg, conn):
        op = msg.get("op")
        if op == "publish":
            e = msg["event"]
            self.publish(make_event(e.get("name"), e.get("source"), e.get("payload"), e.get("priority", "normal"), e.get("ttl", 30)))
            return {"ok": True}
        if op == "state":
            return {"ok": True, "state": self.snapshot()}
        if op == "subscribe":
            with self.lock:
                self.subs.add(conn)
            return {"ok": True}
        raise ValueError(f"unknown op {op!r}")


# ── client ───────────────────────────────────────────────────────────────────

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
