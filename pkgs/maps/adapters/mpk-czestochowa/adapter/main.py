"""Entrypoint: static sync thread, realtime thread, HTTP server."""
import datetime as dt
import json
import logging
import os
import sys
import threading
import time
import tomllib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from guard import Blocked, Guard
from rt import RtClient
from static import GtfsIndex, sync

log = logging.getLogger("main")


class App:
    def __init__(self, cfg, data_dir):
        self.cfg, self.data_dir = cfg, data_dir
        g = cfg["limits"]
        common = dict(state_dir=data_dir, cooldown_s=cfg["breaker"]["cooldown_s"],
                      error_run=cfg["breaker"]["error_run"], kill_file=cfg["breaker"]["kill_file"])
        self.g_static = Guard("static", **g["static"], **common)
        self.g_live = Guard("live", **g["live"], **common)
        self.index = None
        self.static_ok = None
        self.static_err = None
        self.rt = RtClient(cfg, self.g_live, lambda: self.index)
        self.stop = threading.Event()

    def load_index(self):
        path = os.path.join(self.data_dir, "gtfs.zip")
        if os.path.exists(path):
            self.index = GtfsIndex(path)

    def static_loop(self):
        interval = self.cfg["static"]["refresh_interval_s"]
        while not self.stop.is_set():
            try:
                if sync(self.cfg, self.g_static, self.data_dir):
                    self.load_index()
                self.static_ok, self.static_err = time.time(), None
            except (Blocked, OSError, ValueError) as e:
                self.static_err = str(e)
                log.error("static sync failed: %s", e)
            self.stop.wait(interval if not self.static_err else 3600)

    def health(self):
        now = time.time()
        idx = self.index
        rt_age = now - self.rt.last_msg if self.rt.last_msg else None
        breaker = self.g_static.breaker_open() or self.g_live.breaker_open()
        status = "ok"
        if idx is None:
            status = "down"
        elif breaker or self.rt.state in ("blocked", "error"):
            status = "degraded"
        return {
            "status": status,
            "static": {
                "feed_version": idx.version if idx else None,
                "feed_end_date": idx.feed_end if idx else None,
                "last_success": self.static_ok, "last_error": self.static_err,
                "guard": self.g_static.health(),
            },
            "realtime": {
                "state": self.rt.state, "last_message_age_s": rt_age,
                "stats": self.rt.stats,
                "freshness_note": "websocket push roughly every 5 s while in service",
                "guard": self.g_live.health(),
            },
            "quota_remaining": None,
        }


def handler(app):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, ctype, body):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            p = self.path.split("?")[0]
            if p == "/health":
                h = app.health()
                self.send(503 if h["status"] == "down" else 200, "application/json", json.dumps(h).encode())
            elif p == "/gtfs/mpk-czestochowa.zip":
                try:
                    with open(os.path.join(app.data_dir, "gtfs.zip"), "rb") as f:
                        self.send(200, "application/zip", f.read())
                except OSError:
                    self.send(503, "text/plain", b"static feed not ready")
            elif p in ("/gtfs-rt/trip-updates.pb", "/gtfs-rt/vehicle-positions.pb"):
                which = 0 if "trip" in p else 1
                self.send(200, "application/x-protobuf", app.rt.serve(which))
            else:
                self.send(404, "text/plain", b"not found")
    return H


def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    for noisy in ("engineio", "socketio", "websocket"):
        logging.getLogger(noisy).setLevel(logging.WARNING)  # they log payloads at INFO
    cfg_path =os.environ.get("MPK_CONFIG", os.path.join(os.path.dirname(__file__), "..", "config.toml"))
    with open(cfg_path, "rb") as f:
        cfg = tomllib.load(f)
    data_dir = os.environ.get("MPK_DATA", "/data")
    os.makedirs(data_dir, exist_ok=True)
    app = App(cfg, data_dir)
    app.load_index()
    threading.Thread(target=app.static_loop, daemon=True).start()
    threading.Thread(target=app.rt.run, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", cfg["server"]["port"]), handler(app)).serve_forever()


if __name__ == "__main__":
    main()
