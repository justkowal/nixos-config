"""Poll the two GZM realtime feeds, translate ids, serve the results. Static id tables refresh hourly with a conditional request."""
import logging
import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from google.transit import gtfs_realtime_pb2 as pb

from . import translate as tr

log = logging.getLogger("gzm.app")


def rewrite(feed_bytes, services, trips, now, kind):
    """-> (serialized feed, kept, dropped). Entities that cannot be placed are dropped, never guessed."""
    src = pb.FeedMessage()
    src.ParseFromString(feed_bytes)
    out = pb.FeedMessage()
    out.header.CopyFrom(src.header)
    kept = dropped = 0
    for e in src.entity:
        trip = e.trip_update.trip if kind == "tu" else e.vehicle.trip
        hit = tr.translate(trip.trip_id, services, trips, now) if trip.trip_id else None
        if not hit:
            dropped += 1
            continue
        ne = out.entity.add()
        ne.CopyFrom(e)
        t = ne.trip_update.trip if kind == "tu" else ne.vehicle.trip
        t.trip_id, t.start_date = hit
        kept += 1
    return out.SerializeToString(), kept, dropped


class App:
    def __init__(self, cfg, clock=time.time):
        self.cfg, self.clock = cfg, clock
        self.dir = cfg.get("data_dir", "/data")
        self.zip = os.path.join(self.dir, "ids.zip")
        self.etag = os.path.join(self.dir, "ids.etag")
        self.services, self.trips = {}, set()
        self.out = {"tu": b"", "vp": b""}
        self.h = {"ids": {}, "tu": {}, "vp": {}, "blocked_until": 0}
        self.errors = 0
        self.stop = threading.Event()

    def get(self, url, headers=None):
        req = urllib.request.Request(url, headers={"User-Agent": self.cfg["source"]["user_agent"], **(headers or {})})
        with urllib.request.urlopen(req, timeout=self.cfg["source"]["timeout_s"]) as r:
            return r.status, r.read(), r.headers

    def refresh_ids(self):
        h = {}
        try:
            h["If-None-Match"] = open(self.etag).read().strip()
        except OSError:
            pass
        try:
            status, body, hdr = self.get(self.cfg["source"]["static_ids"], h)
            os.makedirs(self.dir, exist_ok=True)
            with open(self.zip + ".tmp", "wb") as f:
                f.write(body)
            os.replace(self.zip + ".tmp", self.zip)
            if hdr.get("ETag"):
                open(self.etag, "w").write(hdr["ETag"])
            self.h["ids"] = {"status": "downloaded", "bytes": len(body), "at": int(self.clock())}
        except urllib.error.HTTPError as e:
            if e.code != 304:
                self.h["ids"] = {"status": f"http {e.code}", "at": int(self.clock())}
                self.trip_breaker(e.code)
                if not self.trips:
                    return
        except Exception as e:  # network trouble: keep serving from the tables already loaded
            self.h["ids"] = {"status": f"error {type(e).__name__}", "at": int(self.clock())}
            if not self.trips and not os.path.exists(self.zip):
                return
        if os.path.exists(self.zip):
            self.services, self.trips = tr.load_ids(self.zip)
            self.h["ids"].update(days=len(self.services), trips=len(self.trips))

    def trip_breaker(self, code):
        if code in (403, 429):
            self.h["blocked_until"] = self.clock() + self.cfg["limits"]["breaker_hours"] * 3600
            log.warning("source answered %s, pausing %s h", code, self.cfg["limits"]["breaker_hours"])

    def poll_once(self):
        if self.clock() < self.h["blocked_until"]:
            return
        for kind, key in (("tu", "trip_updates"), ("vp", "vehicle_positions")):
            try:
                _, body, _ = self.get(self.cfg["source"][key])
                data, kept, dropped = rewrite(body, self.services, self.trips, self.clock(), kind)
                self.out[kind] = data
                self.h[kind] = {"kept": kept, "dropped": dropped, "at": int(self.clock())}
                self.errors = 0
            except urllib.error.HTTPError as e:
                self.errors += 1
                self.h[kind] = {"error": f"http {e.code}", "at": int(self.clock())}
                self.trip_breaker(e.code)
            except Exception as e:
                self.errors += 1
                self.h[kind] = {"error": type(e).__name__, "at": int(self.clock())}

    def loop(self):
        last_ids = 0
        lim = self.cfg["limits"]
        while not self.stop.is_set():
            if self.clock() - last_ids > lim["static_refresh_h"] * 3600:
                self.refresh_ids()
                last_ids = self.clock()
            self.poll_once()
            wait = lim["poll_s"]
            if self.errors >= lim["error_run_limit"]:
                wait = min(lim["backoff_base_s"] * 2 ** (self.errors - lim["error_run_limit"]), lim["backoff_max_s"])
            self.stop.wait(wait)

    def run(self, port):
        threading.Thread(target=self.loop, daemon=True).start()
        app = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                import json
                if self.path == "/health":
                    ok = bool(app.trips) and app.h["tu"].get("kept", 0) > 0
                    body = json.dumps(app.h).encode()
                    self.send_response(200 if ok or not app.out["tu"] else 200)
                    ctype = "application/json"
                elif self.path in ("/gtfs-rt/trip-updates.pb", "/gtfs-rt/vehicle-positions.pb"):
                    body = app.out["tu" if "trip" in self.path else "vp"]
                    self.send_response(200)
                    ctype = "application/x-protobuf"
                else:
                    self.send_response(404)
                    body, ctype = b"", "text/plain"
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
