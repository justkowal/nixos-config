"""Orchestration: static refresh loop, realtime loop, HTTP server, health."""
import hashlib
import json
import logging
import os
import threading
import time
from datetime import date, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import gtfs, rt
from .client import ApiError, Client, NoKey
from .geocode import Geocoder
from .limiter import WAW, Denied, Limiter, next_midnight
from .resolve import resolve
from .schema import SchemaError, load_spec

log = logging.getLogger("plk.app")


def _atomic(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def _hm(s):
    h, m = s.split(":")
    return int(h) * 60 + int(m)


class App:
    def __init__(self, cfg, client=None, limiter=None, geocoder=None, clock=time.time, sleep=time.sleep):
        self.cfg, self.clock, self.sleep = cfg, clock, sleep
        d = cfg["paths"]["data_dir"]
        self.dir, self.out = d, os.path.join(d, "out")
        os.makedirs(self.out, exist_ok=True)
        self.limiter = limiter or Limiter(cfg, os.path.join(d, "limiter.json"), cfg["paths"]["kill_file"])
        self.client = client or Client(cfg, self.limiter, load_spec())
        self.geocoder = geocoder or Geocoder(cfg, os.path.join(d, "geocode.json"),
                                             cfg["paths"]["stop_overrides"])
        self.stop = threading.Event()
        self.index = None
        self.h = {"static": {}, "realtime": {}, "alerts": {}, "key": "unknown", "resolved": {}}
        self._load_index()

    def _load_index(self):
        try:
            with open(os.path.join(self.out, "index.json")) as f:
                self.index = json.load(f)
        except (OSError, ValueError):
            self.index = None

    def _fail(self, part, e):
        h = self.h[part]
        if isinstance(e, Denied):
            h["blocked"] = e.reason
            return
        h["blocked"] = None
        # only our own exception types carry messages that are safe to expose; anything else shows its type alone
        h["last_error"] = ("%s: %s" % (type(e).__name__, e)) if type(e).__module__.startswith("plk_trains") else type(e).__name__
        h["last_error_at"] = int(self.clock())
        if isinstance(e, NoKey):
            self.h["key"] = "missing"
        if isinstance(e, SchemaError):
            h["schema_error"] = True
        log.error("%s update failed: %s", part, h["last_error"][:300])

    def _ok(self, part, **kw):
        h = self.h[part]
        h.update(kw)
        h.update(last_success=int(self.clock()), last_error=None, blocked=None, schema_error=False)
        self.h["key"] = "ok"

    def today(self):
        return datetime.fromtimestamp(self.clock(), WAW).date()

    # static -----------------------------------------------------------
    def static_cycle(self):
        c, today = self.cfg, self.today()
        res = resolve(self.client, c, os.path.join(self.dir, "resolved.json"), self.clock)
        self.h["resolved"] = {"unresolved": res["unresolved"], "carriers": res["carriers"]}
        dv, _ = self.client.get("/api/v1/data-version", None, "DataVersionResponse", prio="static")
        sv = dv["schedulesVersion"]
        cpath = os.path.join(self.dir, "schedules_cache.json")
        try:
            with open(cpath) as f:
                cache = json.load(f)
        except (OSError, ValueError):
            cache = None
        left = (date.fromisoformat(cache["to"]) - today).days if cache else -1
        fresh = cache and cache["version"] == sv and left >= c["static"]["min_remaining_days"]
        if not fresh:
            frm, to = gtfs.window(today, c["static"]["window_days"])
            responses = []
            for p in res["pairs"]:
                if not p["from"] or not p["to"]:
                    continue
                for a, b in ((p["from"], p["to"]), (p["to"], p["from"])):
                    params = {"dateFrom": frm, "dateTo": to, "dictionaries": "true", "fullRoute": "false",
                              "fromStations": ",".join(map(str, a)), "toStations": ",".join(map(str, b))}
                    if res["carriers"]:
                        params["carriersInclude"] = ",".join(res["carriers"])
                    data, _ = self.client.get("/api/v1/schedules", params, "ScheduleResponseDto",
                                              prio="static")
                    responses.append(data)
            cache = {"version": sv, "from": frm, "to": to, "responses": responses}
            _atomic(cpath, json.dumps(cache).encode())
        elif self.index and self.index.get("built_for") == today.isoformat():
            self._ok("static", schedules_version=sv, note="unchanged")
            return
        zbytes, index, stats = gtfs.build(cache["responses"], self.geocoder, today, c, sv)
        _atomic(os.path.join(self.out, "gtfs.zip"), zbytes)
        _atomic(os.path.join(self.out, "index.json"), json.dumps(index).encode())
        self.index = index
        self._ok("static", schedules_version=sv, window=[cache["from"], cache["to"]], stats=stats,
                 sha256=hashlib.sha256(zbytes).hexdigest()[:16])

    def static_loop(self):
        while not self.stop.is_set():
            try:
                self.static_cycle()
            except Exception as e:
                self._fail("static", e)
            wait = self.cfg["static"]["check_interval_hours"] * 3600
            if isinstance(self.h["static"].get("blocked"), str):
                wait = 600
            self.stop.wait(wait)

    # realtime ---------------------------------------------------------
    def stations_param(self):
        return ",".join(sorted({s for t in self.index["trips"].values() for s in t["stops"]}, key=int))

    def poll_ops(self):
        r = self.cfg["realtime"]
        trains, snap, page = [], None, 1
        while True:
            params = {"stations": self.stations_param(), "withPlanned": "true", "page": page,
                      "fullRoutes": str(r["full_routes"]).lower(), "pageSize": r["page_size"]}
            if self.h["resolved"].get("carriers"):
                params["carriersInclude"] = ",".join(self.h["resolved"]["carriers"])
            data, hdr = self.client.get("/api/v1/operations", params, "OperationResponseDto")
            trains += data["trains"] or []
            snap = snap or hdr.get("x-snapshot-timestamp") or data.get("generatedAt")
            pag = data.get("pagination") or {}
            more = pag.get("hasNextPage", page < pag.get("totalPages", page))
            if not more or page >= r["max_pages"]:
                break
            page += 1
        ts = datetime.fromisoformat(snap.replace("Z", "+00:00")).timestamp() if snap else self.clock()
        if self.clock() - ts > r["max_snapshot_age_s"]:
            raise ApiError("snapshot too old: %ds" % (self.clock() - ts))
        blob, st = rt.build_trip_updates(trains, self.index, ts)
        _atomic(os.path.join(self.out, "trip-updates.pb"), blob)
        vp_blob, vp_st = rt.build_vehicle_positions(trains, self.index, ts)
        _atomic(os.path.join(self.out, "vehicle-positions.pb"), vp_blob)
        ratio = st["matched"] / max(st["matched"] + st["unmatched"], 1)
        self._ok("realtime", snapshot_ts=int(ts), stats=st, match_ratio=round(ratio, 3), pages=page)

    def poll_alerts(self):
        today = self.today().isoformat()
        data, _ = self.client.get("/api/v1/disruptions", {
            "dateFrom": today, "dateTo": today, "stations": self.stations_param(),
            "dictionaries": "true"}, "DisruptionResponseDto")
        blob, st = rt.build_alerts(data, self.index, self.clock())
        _atomic(os.path.join(self.out, "alerts.pb"), blob)
        self._ok("alerts", stats=st)

    def quiet_now(self, now):
        r = self.cfg["realtime"]
        d = datetime.fromtimestamp(now, WAW)
        m = d.hour * 60 + d.minute
        return _hm(r["quiet_start"]) <= m < _hm(r["quiet_end"])

    def active_seconds_left(self, now):
        r = self.cfg["realtime"]
        d = datetime.fromtimestamp(now, WAW)
        left = next_midnight(now) - now
        qs = d.replace(hour=0, minute=0, second=0).timestamp() + _hm(r["quiet_start"]) * 60
        qe = d.replace(hour=0, minute=0, second=0).timestamp() + _hm(r["quiet_end"]) * 60
        left -= max(0, qe - max(now, qs))
        return max(left, 1)

    def interval(self):
        r, now = self.cfg["realtime"], self.clock()
        left = self.active_seconds_left(now)
        allow = self.limiter.daily_allowance() * 0.9
        if r["alerts_enabled"]:
            allow -= left / r["alerts_interval_s"]
        allow /= max(self.h["realtime"].get("pages", 1), 1)
        if allow < 1:
            return r["poll_max_s"]
        return min(max(left / allow, r["poll_min_s"]), r["poll_max_s"])

    def rt_loop(self):
        r, last_alerts = self.cfg["realtime"], 0.0
        while not self.stop.is_set():
            now = self.clock()
            if not self.index:
                self.stop.wait(60)
                continue
            if self.quiet_now(now):
                self.stop.wait(300)
                continue
            try:
                self.poll_ops()
            except Exception as e:
                self._fail("realtime", e)
            if r["alerts_enabled"] and self.clock() - last_alerts >= r["alerts_interval_s"]:
                last_alerts = self.clock()
                try:
                    self.poll_alerts()
                except Exception as e:
                    self._fail("alerts", e)
            wait = self.interval()
            self.h["realtime"]["interval_s"] = int(wait)
            self.stop.wait(wait)

    # health -----------------------------------------------------------
    def health(self):
        now = self.clock()
        lim = self.limiter.snapshot()
        h = json.loads(json.dumps(self.h))
        for part in ("static", "realtime", "alerts"):
            ls = h[part].get("last_success")
            h[part]["age_s"] = int(now - ls) if ls else None
        problems, status = [], "ok"
        if h["key"] == "missing":
            problems.append("api key file missing or empty")
        if lim["breaker"]["open"]:
            problems.append("circuit breaker open")
        if lim["kill_switch"]:
            problems.append("kill switch")
        if self.index is None:
            problems.append("no static feed yet")
        if any(h[p].get("schema_error") for p in ("static", "realtime", "alerts")):
            problems.append("api schema changed")
        if problems:
            status = "error" if self.index is None or lim["breaker"]["open"] else "degraded"
        rts = h["realtime"].get("age_s")
        if status == "ok" and lim["quota_pause"]["active"]:
            status, problems = "degraded", ["quota pause"]
        if status == "ok" and rts is not None and rts > 3 * self.cfg["realtime"]["poll_max_s"] \
                and not self.quiet_now(now):
            status, problems = "degraded", ["realtime stale"]
        h["resolved"]["unresolved_count"] = len(h["resolved"].get("unresolved", []))
        return {"status": status, "problems": problems, "now": int(now), "api_version": "v1 (spec 1.1.4)",
                "quota": lim, "requests_total": self.client.requests_total, **h}

    # http -------------------------------------------------------------
    def serve(self, port):
        app = self
        files = {"/gtfs.zip": ("gtfs.zip", "application/zip"),
                 "/gtfs-rt/trip-updates.pb": ("trip-updates.pb", "application/x-protobuf"),
                 "/gtfs-rt/vehicle-positions.pb": ("vehicle-positions.pb", "application/x-protobuf"),
                 "/gtfs-rt/alerts.pb": ("alerts.pb", "application/x-protobuf")}

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body, ctype, extra=None):
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                for k, v in (extra or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                path = self.path.split("?")[0]
                if path == "/health":
                    hd = app.health()
                    return self._send(503 if hd["status"] == "error" else 200,
                                      json.dumps(hd).encode(), "application/json")
                if path in files:
                    name, ctype = files[path]
                    try:
                        with open(os.path.join(app.out, name), "rb") as f:
                            body = f.read()
                        mt = os.path.getmtime(os.path.join(app.out, name))
                    except OSError:
                        return self._send(503, b"not ready", "text/plain")
                    etag = '"%s"' % hashlib.sha256(body).hexdigest()[:16]
                    if self.headers.get("If-None-Match") == etag:
                        return self._send(304, b"", ctype, {"ETag": etag})
                    lm = time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(mt))
                    return self._send(200, body, ctype, {"ETag": etag, "Last-Modified": lm})
                self._send(404, b"not found", "text/plain")

        srv = ThreadingHTTPServer(("0.0.0.0", port), H)
        srv.daemon_threads = True
        return srv

    def run(self, port=8080):
        for fn in (self.static_loop, self.rt_loop):
            threading.Thread(target=fn, daemon=True).start()
        srv = self.serve(port)
        log.info("listening on %d", port)
        srv.serve_forever()


__all__ = ["App", "timedelta"]
