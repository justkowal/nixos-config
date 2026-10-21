"""Offline tests on recorded fixtures (2026-10-21). Nothing here touches the live site.

The only sockets are loopback servers the tests start themselves.
"""
import base64
import json
import os
import sys
import tempfile
import threading
import tomllib
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "adapter"))

import crawl  # noqa: E402
import gtfs  # noqa: E402
import guard as guard_mod  # noqa: E402
import main as main_mod  # noqa: E402
from client import Source  # noqa: E402
from google.transit import gtfs_realtime_pb2 as pb  # noqa: E402
from guard import Blocked, Guard, SourceError  # noqa: E402
from rt import Rt  # noqa: E402
from store import Store  # noqa: E402

FX = os.path.join(HERE, "fixtures")
CFG = tomllib.load(open(os.path.join(HERE, "..", "config.toml"), "rb"))
NOW = 1792565108  # 2026-10-21 08:45:08 Europe/Warsaw, when the timetable fixtures were recorded
NOW_DEP = 1792565265  # departures_multi.json
BLACH = "2303517:2391682"
UA = CFG["source"]["user_agent"]


def fx(name, raw=False):
    with open(os.path.join(FX, name), "rb") as f:
        b = f.read()
    return b if raw else json.loads(b)


class FixtureSource(Source):
    """Real client code, canned transport."""

    def __init__(self):
        super().__init__(None, "http://x", UA)
        self.paths = []

    def _get(self, lane, path, **kw):
        self.paths.append(path)
        if path == "/":
            return fx("home.html", raw=True)
        if path.startswith("/stops?rev="):
            return fx("stops.json", raw=True)
        if path.startswith("/api/timetables/"):
            pid, date = urllib.parse.unquote(path.split("/")[3].split("?")[0]), path.split("date=")[1]
            if pid == BLACH and date in ("2026-10-21", "2026-10-22"):
                return fx(f"timetable_{date}.json", raw=True)
            return b'{"departures": [], "directions": []}'
        if path.startswith("/api/trip/"):
            _, _, _, tid, idx = path.split("/")
            return fx(f"trips/{tid}.json", raw=True)
        if path.startswith("/api/departures?places="):
            return fx("departures_multi.json", raw=True)
        if path.startswith("/api/trip_execution/"):
            eid = base64.b64decode(path.split("/")[3]).decode()
            if eid == "151:739910:4":
                return fx("trip_execution.json", raw=True)
            raise SourceError("HTTP 404")
        raise AssertionError(path)


def tmp_cfg(**static):
    cfg = json.loads(json.dumps(CFG))
    cfg["static"].update(seed_stops=[BLACH], **static)
    return cfg


def crawled(tmp, **static):
    cfg = tmp_cfg(**static)
    src, store = FixtureSource(), Store(os.path.join(tmp, "state.json"))
    c = crawl.Crawler(cfg, store, src, clock=lambda: NOW)
    n = 0
    while c.step():
        n += 1
        assert n < 500
    return cfg, src, store, c


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.t = [1000.0]
        self.slept = []

    def mk(self, **kw):
        base = dict(state_dir=self.d, lanes={"static": 40, "rt": 60}, spacing_s=5, jitter_s=0, hourly_budget=100,
                    clock=lambda: self.t[0], sleep=lambda s: self.slept.append(s) or self.t.__setitem__(0, self.t[0] + s),
                    rand=lambda a, b: 0)
        base.update(kw)
        return Guard(**base)

    def test_floors_cannot_be_lowered(self):
        g = self.mk(spacing_s=0.1, hourly_budget=5000, cooldown_s=60, lanes={"static": 900})
        self.assertEqual((g.spacing, g.budget, g.cooldown, g.lanes["static"]), (5.0, 100, 21600, 100))

    def test_spacing_enforced(self):
        g = self.mk()
        g.acquire("rt")
        g.acquire("rt")
        self.assertGreaterEqual(sum(self.slept), 5)

    def test_lane_and_total_budget(self):
        g = self.mk()
        for _ in range(40):
            g.acquire("static")
        with self.assertRaises(Blocked) as cm:
            g.acquire("static")
        self.assertGreater(cm.exception.retry_in, 0)
        for _ in range(60):
            g.acquire("rt")
        with self.assertRaises(Blocked):
            g.acquire("rt")
        self.assertEqual(g.used(), 100)
        self.t[0] += 3601
        g.acquire("static")

    def test_ban_signals_trip_breaker_for_six_hours_and_persist(self):
        for kw in ({"status": 403}, {"status": 429}, {"status": 200, "redirected": False, "blocked_body": True},
                   {"status": 302, "redirected": True}):
            g = self.mk()
            g.breaker_until = 0
            g.record(**kw)
            self.assertTrue(g.breaker_open(), kw)
            self.assertEqual(g.breaker_until - self.t[0], 21600)
            g2 = self.mk()
            with self.assertRaises(Blocked):
                g2.acquire("rt")
        self.t[0] += 21601
        self.mk().acquire("rt")

    def test_error_run_and_backoff(self):
        g = self.mk()
        g.acquire("rt")
        g.record(status=500)
        self.slept.clear()
        g.acquire("rt")
        self.assertGreaterEqual(sum(self.slept), 5 + 30)
        for _ in range(4):
            g.record(status=500)
        self.assertTrue(g.breaker_open())
        self.assertIn("consecutive errors", g.breaker_reason)

    def test_success_resets_errors(self):
        g = self.mk()
        g.record(status=500)
        g.record(status=200)
        self.assertEqual(g.errors, 0)

    def test_kill_switch(self):
        kill = os.path.join(self.d, "KILL")
        g = self.mk(kill_file=kill)
        g.acquire("rt")
        open(kill, "w").close()
        with self.assertRaises(Blocked):
            g.acquire("rt")
        self.assertTrue(g.health()["killed"])


class _H(BaseHTTPRequestHandler):
    seen_ua = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        _H.seen_ua.append(self.headers.get("User-Agent"))
        p = self.path
        if p == "/ok":
            body, code, hdr = b'{"a": 1}', 200, {}
        elif p == "/forbidden":
            body, code, hdr = b"nope", 403, {}
        elif p == "/limited":
            body, code, hdr = b"slow down", 429, {}
        elif p == "/moved":
            body, code, hdr = b"", 302, {"Location": "/blocked"}
        elif p == "/html":
            body, code, hdr = b"<html>checking your browser</html>", 200, {}
        elif p == "/cf":
            body, code, hdr = b"<html>Just a moment... cloudflare</html>", 503, {}
        else:
            body, code, hdr = b"missing", 404, {}
        self.send_response(code)
        for k, v in hdr.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class FetchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = HTTPServer(("127.0.0.1", 0), _H)
        cls.base = f"http://127.0.0.1:{cls.srv.server_port}"
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def g(self):
        t = [0.0]
        return Guard(tempfile.mkdtemp(), {"rt": 60}, clock=lambda: t[0], sleep=lambda s: None, rand=lambda a, b: 0)

    def test_ok_sends_honest_user_agent(self):
        g = self.g()
        _H.seen_ua.clear()
        status, _, body = guard_mod.fetch(g, "rt", self.base + "/ok", UA)
        self.assertEqual((status, json.loads(body)), (200, {"a": 1}))
        self.assertEqual(_H.seen_ua, [UA])
        self.assertFalse(g.breaker_open())

    def test_ban_signals_stop_everything(self):
        for path in ("/forbidden", "/limited", "/moved", "/html", "/cf"):
            g = self.g()
            with self.assertRaises(Blocked, msg=path):
                guard_mod.fetch(g, "rt", self.base + path, UA)
            self.assertTrue(g.breaker_open(), path)

    def test_plain_404_is_an_error_not_a_ban(self):
        g = self.g()
        with self.assertRaises(SourceError):
            guard_mod.fetch(g, "rt", self.base + "/gone", UA)
        self.assertFalse(g.breaker_open())
        self.assertEqual(g.errors, 1)


class ClientTests(unittest.TestCase):
    def test_parsers(self):
        s = FixtureSource()
        self.assertEqual(s.stops_revision(), 9885)
        stops = s.stops(9885)
        self.assertAlmostEqual(stops[BLACH]["lat"], 50.773215)
        self.assertEqual(stops["622548"]["station"], True)
        self.assertEqual(len(s.timetable(BLACH, "2026-10-21")), 19)
        self.assertEqual(s.trip(38155603, 17)["line"]["name"], "151")
        self.assertEqual(len(s.departures([BLACH, "622548"])["departures"]), 2)
        self.assertEqual(s.trip_execution("151:739910:4", 17)["vehicle_trip_index"], 9)
        self.assertTrue(s.paths[-1].startswith("/api/trip_execution/MTUxOjczOTkxMDo0/"))

    def test_shape_errors(self):
        s = FixtureSource()
        s._get = lambda lane, path, **kw: b'{"nothing": 1}'
        for f in (lambda: s.stops(1), lambda: s.timetable(BLACH, "2026-10-21"), lambda: s.trip(1, 1),
                  lambda: s.departures([BLACH])):
            with self.assertRaises(SourceError):
                f()


class CrawlTests(unittest.TestCase):
    def test_trip_seconds_anchor_and_midnight(self):
        raw = {"times": [{"departure_time": t, "index": i} for i, t in enumerate(["23:50", "00:10", "00:30"])]}
        self.assertEqual(crawl.trip_seconds(raw, 1, 86400 + 600), [85800 + 0, 87000, 88200])
        self.assertEqual(crawl.trip_seconds(raw, 0, 85800), [85800, 87000, 88200])
        with self.assertRaises(SourceError):
            crawl.trip_seconds(raw, 0, 85800 + 60)

    def test_full_crawl_from_fixtures(self):
        with tempfile.TemporaryDirectory() as d:
            cfg, src, store, c = crawled(d)
            s = store.s
            self.assertEqual(len(s["trips"]), 19)
            self.assertEqual(sorted(s["seen"]["38155603"]), ["2026-10-21", "2026-10-22"])
            self.assertEqual(s["cover"], [BLACH])
            kinds = [p.split("?")[0].split("/")[2] if p.startswith("/api") else p.split("?")[0] for p in src.paths]
            self.assertEqual(kinds.count("/"), 1)
            self.assertEqual(kinds.count("/stops"), 1)
            self.assertEqual(kinds.count("trip"), 19)
            # 7 window days for the one cover stop, then probes of stops no known trip serves
            n_tt = kinds.count("timetables")
            unserved = len(set(s["stops"]) - store.served_stops() - {BLACH})
            self.assertEqual(n_tt, 7 + 3 * unserved)
            self.assertEqual(c.step(), None)  # nothing left, no request
            self.assertLessEqual(s["probe_day"]["n"], cfg["static"]["probe_per_day"])

    def test_probe_cap_per_day(self):
        with tempfile.TemporaryDirectory() as d:
            _, src, store, _ = crawled(d, probe_per_day=4)
            self.assertEqual(store.s["probe_day"]["n"], 4)

    def test_unchanged_upstream_trip_is_refetched(self):
        with tempfile.TemporaryDirectory() as d:
            _, src, store, c = crawled(d)
            rows = fx("timetable_2026-10-21.json")["departures"]
            rows[0]["departure"] += 600
            c._ingest(BLACH, "2026-10-21", rows, NOW)
            self.assertNotIn(str(rows[0]["trip_id"]), store.s["trips"])

    def test_bad_trip_is_rejected_not_fatal(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = tmp_cfg()
            src, store = FixtureSource(), Store(os.path.join(d, "state.json"))
            orig = src.trip
            src.trip = lambda tid, idx: orig(tid, idx + 0) if str(tid) != "38155599" else (_ for _ in ()).throw(SourceError("HTTP 404"))
            c = crawl.Crawler(cfg, store, src, clock=lambda: NOW)
            while c.step():
                pass
            self.assertIn("38155599", store.s["rejected"])
            self.assertEqual(len(store.s["trips"]), 18)


class GtfsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        _, _, cls.store, _ = crawled(cls.tmp)
        cls.data, cls.stats = gtfs.build(cls.store, NOW, cls.store.coverage())
        cls.idx = gtfs.Index(cls.data)

    def test_content(self):
        self.assertEqual(self.stats["trips"], 19)
        self.assertEqual(self.stats["routes"], 2)
        self.assertEqual(set(self.idx.routes), {"line-151", "line-105"})
        self.assertIn("38155603", self.idx.trips)
        self.assertEqual(self.idx.stop_at("38155603", 17), BLACH)
        self.assertEqual(self.idx.times["38155603"][17][1], 31980)
        self.assertTrue(self.idx.active("38155603", "20261021"))
        self.assertFalse(self.idx.active("38155603", "20261023"))
        self.assertIn("-cov", self.idx.version)

    def test_deterministic_and_stable_ids(self):
        again, _ = gtfs.build(self.store, NOW, self.store.coverage())
        self.assertEqual(again, self.data)

    def test_only_used_stops_and_known_coordinates(self):
        self.assertTrue(set(self.idx.stops) <= set(self.store.s["stops"]))
        self.assertTrue(all(r["stop_lat"] and r["stop_lon"] for r in self.idx.stops.values()))

    def test_trip_with_unknown_stop_is_dropped_and_counted(self):
        s = Store(os.path.join(self.tmp, "other.json"))
        s.s = json.loads(json.dumps(self.store.s))
        s.s["trips"]["38155603"]["stops"][0][0] = "nope"
        data, stats = gtfs.build(s, NOW, s.coverage())
        self.assertEqual(stats["dropped"]["unknown_stop"], 1)
        self.assertNotIn("38155603", gtfs.Index(data).trips)

    def test_past_dates_leave_the_calendar(self):
        data, stats = gtfs.build(self.store, NOW + 86400 * 2, self.store.coverage())
        self.assertIsNone(data)
        self.assertEqual(stats["dropped"]["no_dates"], 19)


class RtTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        _, _, self.store, _ = crawled(self.tmp)
        data, _ = gtfs.build(self.store, NOW, self.store.coverage())
        self.idx = gtfs.Index(data)
        self.rt = Rt()
        self.rt.set_static(self.idx, self.store.s["stops"])
        self.src = FixtureSource()

    def feed(self, which, now=NOW_DEP + 5):
        f = pb.FeedMessage()
        f.ParseFromString(self.rt.build(now)[which])
        return f

    def test_not_ready_before_first_poll(self):
        self.assertIsNone(self.rt.build(NOW))

    def test_departures_matching_and_delay(self):
        resp = self.src.departures([BLACH, "622548"])
        cands = self.rt.ingest_departures(resp, NOW_DEP)
        st = self.rt.stats
        self.assertEqual((st["rows_seen"], st["rows_matched"]), (25, 5))
        self.assertEqual(st["unmatched_reasons"], {"trip not in static feed": 20})
        tu = self.feed(0)
        self.assertEqual(tu.header.incrementality, pb.FeedHeader.FULL_DATASET)
        self.assertEqual(tu.header.timestamp, NOW_DEP)
        ents = {e.trip_update.trip.trip_id: e.trip_update for e in tu.entity}
        u = ents["38155603"]
        self.assertEqual(u.trip.start_date, "20261021")
        self.assertEqual(u.trip.route_id, "line-151")
        self.assertEqual((u.stop_time_update[0].stop_sequence, u.stop_time_update[0].stop_id), (17, BLACH))
        self.assertEqual(u.stop_time_update[0].departure.delay, 120)
        self.assertIn("38155604", ents)
        self.assertNotIn("37634158", ents)  # not is_estimated, so schedule only, no update
        self.assertEqual([c[1] for c in cands][:1], ["38155603"])
        self.assertEqual(cands[0][3], "151:739910:4")

    def test_execution_gives_vehicle_and_stop_delays(self):
        self.rt.ingest_departures(self.src.departures([BLACH]), NOW_DEP)
        ok = self.rt.ingest_execution("38155603", "20261021", self.src.trip_execution("151:739910:4", 17), NOW_DEP)
        self.assertTrue(ok)
        vp = self.feed(1)
        v = vp.entity[0].vehicle
        self.assertEqual((v.trip.trip_id, v.trip.start_date, v.trip.route_id), ("38155603", "20261021", "line-151"))
        self.assertEqual((v.current_stop_sequence, v.current_status), (10, pb.VehiclePosition.IN_TRANSIT_TO))
        self.assertAlmostEqual(v.position.latitude, 50.785007, places=4)
        self.assertEqual(v.stop_id, self.idx.stop_at("38155603", 10))
        tu = [e.trip_update for e in self.feed(0).entity if e.trip_update.trip.trip_id == "38155603"][0]
        seqs = [u.stop_sequence for u in tu.stop_time_update]
        self.assertEqual(seqs, sorted(set(seqs)))
        self.assertEqual(seqs[-1], 36)
        self.assertTrue(all(u.stop_id == self.idx.stop_at("38155603", u.stop_sequence) for u in tu.stop_time_update))
        self.assertTrue(all(u.arrival.delay == 0 for u in tu.stop_time_update if u.stop_sequence >= 10))

    def test_execution_mismatch_is_rejected(self):
        self.rt.ingest_departures(self.src.departures([BLACH]), NOW_DEP)
        raw = self.src.trip_execution("151:739910:4", 17)
        raw["trip"]["times"][12]["place_id"] = "other"
        self.assertFalse(self.rt.ingest_execution("38155603", "20261021", raw, NOW_DEP))
        self.assertEqual(self.rt.stats["executions_unmatched"], 1)

    def test_start_date_yesterday_for_after_midnight_trip(self):
        idx = self.idx
        tid = "38155611"
        idx.times[tid][0] = (idx.times[tid][0][0], 25 * 3600)  # 01:00 the next calendar day
        idx.dates["svc-" + tid] = {"20261021"}
        now = 1792620000 + 3600  # 2026-10-22 01:00 local
        self.assertEqual(self.rt.start_date(tid, 0, now), "20261021")
        self.assertIsNone(self.rt.start_date(tid, 0, now + 86400))

    def test_skipped_and_entries_expire(self):
        resp = self.src.departures([BLACH])
        resp["departures"][0]["rows"][1]["canceled"] = True
        self.rt.ingest_departures(resp, NOW_DEP)
        tu = [e.trip_update for e in self.feed(0).entity if e.trip_update.trip.trip_id == "38155603"][0]
        self.assertEqual(tu.stop_time_update[0].schedule_relationship,
                         pb.TripUpdate.StopTimeUpdate.SKIPPED)
        self.assertEqual(len(self.feed(0, now=NOW_DEP + 10_000).entity), 0)

    def test_wrong_stop_at_sequence_not_matched(self):
        resp = self.src.departures([BLACH])
        resp["departures"][0]["rows"][1]["trip_index"] = 16
        self.rt.ingest_departures(resp, NOW_DEP)
        self.assertIn("stop does not match static trip at that sequence", self.rt.stats["unmatched_reasons"])


class AppTests(unittest.TestCase):
    def mk(self):
        d = tempfile.mkdtemp()
        cfg = tmp_cfg()
        cfg["breaker"]["kill_file"] = os.path.join(d, "KILL")
        app = main_mod.App(cfg, d, clock=lambda: NOW_DEP)
        app.src = FixtureSource()
        app.crawler = crawl.Crawler(cfg, app.store, app.src, clock=lambda: NOW)
        return app

    def test_quiet_hours(self):
        self.assertTrue(main_mod.in_quiet(1792618800, "23:30", "04:00"))  # 2026-10-22 00:20 local
        self.assertFalse(main_mod.in_quiet(NOW, "23:30", "04:00"))

    def test_health_down_then_ok_and_poll_budget(self):
        app = self.mk()
        self.assertEqual(app.health()["status"], "down")
        while app.crawler.step():
            pass
        app.clock = lambda: NOW
        app.rebuild()
        app.clock = lambda: NOW_DEP
        h = app.health()
        self.assertEqual(h["status"], "ok")
        self.assertEqual(h["static"]["published"]["trips"], 19)
        self.assertEqual(h["static"]["coverage"]["stops_total"], 79)
        app.src.paths.clear()
        app.poll_once(NOW_DEP)
        self.assertEqual([p.split("?")[0].split("/")[2] for p in app.src.paths], ["departures", "trip_execution"])
        app.cfg["realtime"]["execution_window_s"] = 86400
        app.cfg["realtime"]["trips_per_cycle_idle"] = 2
        app.src.paths.clear()
        app.poll_once(NOW_DEP)
        self.assertEqual([p.split("?")[0].split("/")[2] for p in app.src.paths],
                         ["departures"] + ["trip_execution"] * 2)
        app.boost()
        self.assertEqual(app.mode(NOW_DEP), "boost")
        app.src.paths.clear()
        app.poll_once(NOW_DEP)
        self.assertEqual(len(app.src.paths), 2)  # one departures call plus a single execution call

    def test_http_endpoints(self):
        app = self.mk()
        while app.crawler.step():
            pass
        app.rebuild()
        srv = HTTPServer(("127.0.0.1", 0), main_mod.handler(app))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            import urllib.error
            import urllib.request
            base = f"http://127.0.0.1:{srv.server_port}"
            r = urllib.request.urlopen(base + "/gtfs/komunikacja-jurajska.zip")
            etag = r.headers["ETag"]
            self.assertEqual(r.read()[:2], b"PK")
            req = urllib.request.Request(base + "/gtfs/komunikacja-jurajska.zip", headers={"If-None-Match": etag})
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(req)
            self.assertEqual(cm.exception.code, 304)
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(base + "/gtfs-rt/trip-updates.pb")
            self.assertEqual(cm.exception.code, 503)
            self.assertIn(b'"breaker": "closed"', urllib.request.urlopen(base + "/health").read())
        finally:
            srv.shutdown()


if __name__ == "__main__":
    unittest.main()
