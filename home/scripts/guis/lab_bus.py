"""Kowal Lab state bus client: newline-delimited JSON over a unix socket.

The server is labd (pkgs/labd/src/bus.rs). This module is the client side for the lab CLI and
Python providers. The event contract lives in bus.rs; publish with lab-publish. Stdlib only.
"""

import json
import os
import socket


def sock_path():
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "lab.sock")


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
