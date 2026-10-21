"""Entrypoint: static crawl thread, realtime thread, HTTP server."""
import hashlib
import json
import logging
import os
import sys
import threading
import time
import tomllib
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import crawl
import gtfs
from client import Source
from guard import Blocked, Guard, SourceError
from rt import Rt
from store import WAW, Store, today_waw

log = logging.getLogger("main")


def in_quiet(now, start, end):
    t = datetime.fromtimestamp(now, WAW).strftime("%H:%M")
    return (start <= t < end) if start <= end else (t >= start or t < end)


class App:
    def __init__(self, cfg, data_dir, clock=time.time):
        self.cfg, self.data_dir, self.clock = cfg, data_dir, clock
        lim = cfg["limits"]
        self.guard = Guard(
            data_dir, lanes={"static": lim["static_hourly"], "rt": lim["rt_hourly"]},
            spacing_s=lim["spacing_s"], jitter_s=lim["jitter_s"], hourly_budget=lim["hourly_budget"],
            cooldown_s=cfg["breaker"]["cooldown_s"], error_run=cfg["breaker"]["error_run"],
            kill_file=cfg["breaker"]["kill_file"])
        self.src = Source(self.guard, cfg["source"]["base_url"], cfg["source"]["user_agent"])
        self.store = Store(os.path.join(data_dir, "state.json"))
        self.crawler = crawl.Crawler(cfg, self.store, self.src, clock)
        r = cfg["realtime"]
        self.rt = Rt(max_age_s=r["max_age_s"], horizon_s=r["match_horizon_s"])
        self.zip_path = os.path.join(data_dir, "gtfs.zip")
        self.zip_etag = None
        self.build_stats = {}
        self.last_build = 0.0
        self.last_build_date = None
        self.dirty = False
        self.static_err = None
        self.rt_err = None
        self.boost_until = 0.0
        self.stop = threading.Event()
        self.wake = threading.Event()
        self.lock = threading.Lock()

    # static -------------------------------------------------------------
    def load_zip(self):
        try:
            with open(self.zip_path, "rb") as f:
                data = f.read()
            idx = gtfs.Index(data)
        except (OSError, ValueError, KeyError):
            return
        self.zip_etag = hashlib.sha1(data).hexdigest()
        self.rt.set_static(idx, self.store.s["stops"])

    def rebuild(self):
        now = self.clock()
        data, stats = gtfs.build(self.store, now, self.store.coverage())
        self.last_build, self.last_build_date, self.dirty = now, today_waw(now), False
        self.build_stats = stats
        if data is None:
            log.info("nothing to publish yet: %s", stats)
            return
        tmp = self.zip_path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, self.zip_path)
        self.load_zip()
        log.info("published gtfs: %s", {k: v for k, v in stats.items() if k != "dropped"})

    def static_loop(self):
        interval = self.cfg["static"]["rebuild_interval_s"]
        while not self.stop.is_set():
            wait = 0
            try:
                job = self.crawler.step()
                self.static_err = None
                if job:
                    self.dirty = True
                else:
                    wait = self.cfg["static"]["idle_sleep_s"]
            except Blocked as b:
                self.static_err = f"blocked: {b}"
                wait = min(max(b.retry_in or 60, 30), 3600)
                log.warning("static crawl paused %ds: %s", wait, b)
            except SourceError as e:
                self.static_err = str(e)
                wait = 300
                log.error("static crawl error: %s", e)
            now = self.clock()
            new_day = self.last_build_date != today_waw(now)
            gap = interval if self.zip_etag else 300  # first publish early so /health leaves "down"
            if (self.dirty and now - self.last_build > gap) or (new_day and self.store.s["trips"]) \
                    or (wait and self.dirty):
                try:
                    self.rebuild()
                except Exception:
                    log.exception("rebuild failed")
            if wait:
                self.stop.wait(wait)

    # realtime -----------------------------------------------------------
    def mode(self, now):
        r = self.cfg["realtime"]
        if in_quiet(now, r["quiet_start"], r["quiet_end"]):
            return "quiet"
        return "boost" if now < self.boost_until else "idle"

    def poll_once(self, now):
        r = self.cfg["realtime"]
        resp = self.src.departures(r["priority_stops"][: r["max_stops_per_call"]])
        cands = self.rt.ingest_departures(resp, now)
        k = r["trips_per_cycle_boost"] if self.mode(now) == "boost" else r["trips_per_cycle_idle"]
        near = [c for c in cands if -300 <= c[0] - now <= r["execution_window_s"]][:k]
        for _, tid, sd, eid, seq in near:
            try:
                self.rt.ingest_execution(tid, sd, self.src.trip_execution(eid, seq), self.clock())
            except (SourceError, KeyError, TypeError) as e:
                log.warning("trip_execution for trip %s skipped: %s", tid, e)

    def rt_loop(self):
        r = self.cfg["realtime"]
        while not self.stop.is_set():
            now = self.clock()
            mode = self.mode(now)
            wait = r["boost_interval_s"] if mode == "boost" else r["idle_interval_s"]
            if mode == "quiet" or self.rt.idx is None or not r["priority_stops"]:
                wait = 60
            else:
                try:
                    self.poll_once(now)
                    self.rt_err = None
                except Blocked as b:
                    self.rt_err = f"blocked: {b}"
                    wait = min(max(b.retry_in or 60, 30), 3600)
                    log.warning("realtime paused %ds: %s", wait, b)
                except (SourceError, KeyError, TypeError, ValueError) as e:
                    self.rt_err = str(e)
                    wait = max(wait, 120)
                    log.error("realtime error: %s", e)
            self.wake.wait(wait)
            self.wake.clear()

    def boost(self):
        self.boost_until = self.clock() + self.cfg["realtime"]["boost_duration_s"]
        self.wake.set()

    # health -------------------------------------------------------------
    def health(self):
        now = self.clock()
        g = self.guard.health()
        s = self.store.s
        poll = self.rt.last_poll_ok
        have_static = self.zip_etag is not None
        status = "ok"
        if not have_static:
            status = "down"
        elif g["breaker"] == "open" or g["killed"] or self.static_err or self.rt_err:
            status = "degraded"
        return {
            "status": status,
            "source": {"breaker": g["breaker"], "breaker_reason": g["breaker_reason"],
                       "breaker_until": g["breaker_until"], "killed": g["killed"],
                       "requests_last_hour": g["requests_last_hour"], "hourly_budget": g["hourly_budget"],
                       "lanes_last_hour": g["lanes_last_hour"], "lane_budgets": g["lane_budgets"],
                       "requests_total": g["requests_total"], "last_status": g["last_status"],
                       "status_counts": g["status_counts"], "last_success_age_s": g["last_ok_age_s"]},
            "static": {
                "feed_version": self.build_stats.get("feed_version"),
                "feed_start": self.build_stats.get("feed_start"), "feed_end": self.build_stats.get("feed_end"),
                "published": {k: self.build_stats.get(k) for k in ("trips", "stops", "routes", "dropped")},
                "built_age_s": int(now - self.last_build) if self.last_build else None,
                "coverage": self.store.coverage(),
                "crawl": {"trips_known": len(s["trips"]), "trips_seen": len(s["seen"]),
                          "trips_pending": len([t for t in s["seen"] if t not in s["trips"]]),
                          "trips_rejected": len(s["rejected"]), "cover_stops": len(s["cover"]),
                          "probes_today": s["probe_day"]["n"], "last_job": self.crawler.stats["last_job"]},
                "last_error": self.static_err,
            },
            "realtime": {
                "mode": self.mode(now), "last_poll_age_s": int(now - poll) if poll else None,
                "priority_stops": self.cfg["realtime"]["priority_stops"],
                "coverage_note": "only the priority stops are polled, so only trips calling at them get live data",
                "entries": len(self.rt.entries), "stats": self.rt.stats, "last_error": self.rt_err,
            },
        }


def handler(app):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, ctype, body, extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            p = self.path.split("?")[0]
            if p == "/health":
                h = app.health()
                self.send(503 if h["status"] == "down" else 200, "application/json", json.dumps(h).encode())
            elif p == "/gtfs/komunikacja-jurajska.zip":
                try:
                    with open(app.zip_path, "rb") as f:
                        body = f.read()
                except OSError:
                    return self.send(503, "text/plain", b"static feed not ready")
                tag = '"%s"' % app.zip_etag
                if self.headers.get("If-None-Match") == tag:
                    return self.send(304, "application/zip", b"", {"ETag": tag})
                self.send(200, "application/zip", body, {"ETag": tag})
            elif p in ("/gtfs-rt/trip-updates.pb", "/gtfs-rt/vehicle-positions.pb"):
                out = app.rt.build(app.clock())
                if out is None:
                    return self.send(503, "text/plain", b"no realtime poll yet")
                self.send(200, "application/x-protobuf", out[0 if "trip" in p else 1])
            elif p == "/boost":
                app.boost()
                self.send(200, "text/plain", b"boost on")
            else:
                self.send(404, "text/plain", b"not found")

        do_POST = do_GET
    return H


def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    cfg_path = os.environ.get("KJ_CONFIG", os.path.join(os.path.dirname(__file__), "..", "config.toml"))
    with open(cfg_path, "rb") as f:
        cfg = tomllib.load(f)
    data_dir = os.environ.get("KJ_DATA", "/data")
    os.makedirs(data_dir, exist_ok=True)
    app = App(cfg, data_dir)
    app.load_zip()
    threading.Thread(target=app.static_loop, daemon=True).start()
    threading.Thread(target=app.rt_loop, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", cfg["server"]["port"]), handler(app)).serve_forever()


if __name__ == "__main__":
    main()
