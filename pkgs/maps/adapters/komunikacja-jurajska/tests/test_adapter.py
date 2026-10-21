"""Offline tests on recorded fixtures (2026-10-21). Nothing here touches the live sites.

The only sockets are loopback servers the tests start themselves.
Operator pages in fixtures/op are slimmed recordings (timetable tables, validity, legend, map markers).
"""
import base64
import json
import os
import sys
import tempfile
import threading
import tomllib
import unittest
from datetime import date
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "adapter"))

import calpl  # noqa: E402
import client  # noqa: E402
import crawl  # noqa: E402
import gtfs  # noqa: E402
import guard as guard_mod  # noqa: E402
import main as main_mod  # noqa: E402
import opsite  # noqa: E402
import recon  # noqa: E402
from client import OpSource, Source  # noqa: E402
from google.transit import gtfs_realtime_pb2 as pb  # noqa: E402
from guard import Blocked, Guard, SourceError  # noqa: E402
from rt import Rt  # noqa: E402
from store import Store  # noqa: E402

FX = os.path.join(HERE, "fixtures")
CFG = tomllib.load(open(os.path.join(HERE, "..", "config.toml"), "rb"))
NOW = 1792565108  # 2026-10-21 08:45:08 Europe/Warsaw (a Wednesday)
NOW_DEP = 1792565265  # departures_multi.json
BLACH = "2303517:2391682"
UA = CFG["source"]["user_agent"]
LINES = ["102", "123B", "131", "141", "151"]
CENSUS_REQUESTS = 4  # one fixture line has no same-name stop on kiedyPrzyjedzie, so no request is made for it


def fx(name, raw=False):
    with open(os.path.join(FX, name), "rb") as f:
        b = f.read()
    return b if raw else json.loads(b)


def op_page(name):
    with open(os.path.join(FX, "op", name), encoding="utf-8") as f:
        return f.read()


class FixtureKp(Source):
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
        if path.startswith("/api/trip/"):
            try:
                return fx(f"trips/{path.split('/')[3]}.json", raw=True)
            except FileNotFoundError:
                raise SourceError("HTTP 404") from None
        if path.startswith("/api/departures?places="):
            return fx("departures_multi.json", raw=True)
        if path.startswith("/api/trip_execution/"):
            eid = base64.b64decode(path.split("/")[3]).decode()
            if eid == "151:739910:4":
                return fx("trip_execution.json", raw=True)
            raise SourceError("HTTP 404")
        raise AssertionError(path)

    def line_known(self, place_id, line, date_):
        self.paths.append(f"census {line} {place_id} {date_}")
        return line in ("151", "102")


class FixtureOp(OpSource):
    def __init__(self):
        super().__init__(None, "https://x", UA)
        self.paths = []

    def _page(self, path):
        self.paths.append(path)
        name = "home.html" if path == "/" else path.lstrip("/")
        if not os.path.exists(os.path.join(FX, "op", name)):
            raise SourceError("HTTP 404")
        return op_page(name)


def tmp_cfg(**static):
    cfg = json.loads(json.dumps(CFG))
    cfg["static"].update(static)
    return cfg


def crawled(tmp, now=NOW):
    cfg = tmp_cfg()
    kp, op, store = FixtureKp(), FixtureOp(), Store(os.path.join(tmp, "state.json"))
    c = crawl.Crawler(cfg, store, kp, op, clock=lambda: now)
    n = 0
    while c.step():
        n += 1
        assert n < 200
    return cfg, kp, op, store, c


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
        for kw in ({"status": 403}, {"status": 429}, {"status": 200, "blocked_body": True},
                   {"status": 302, "redirected": True}):
            g = self.mk()
            g.breaker_until = 0
            g.record(**kw)
            self.assertTrue(g.breaker_open(), kw)
            self.assertEqual(g.breaker_until - self.t[0], 21600)
            with self.assertRaises(Blocked):
                self.mk().acquire("rt")
        self.t[0] += 21601
        self.mk().acquire("rt")

    def test_two_sources_have_separate_state(self):
        a, b = self.mk(name="kp"), self.mk(name="op")
        a.record(status=403)
        self.assertTrue(a.breaker_open())
        self.assertFalse(self.mk(name="op").breaker_open())
        self.assertTrue(b is not a)

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

    def test_soft_404_is_not_an_error(self):
        g = self.mk()
        for _ in range(8):
            g.record(status=404, soft=True)
        self.assertFalse(g.breaker_open())

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
        table = {"/ok": (b'{"a": 1}', 200, {}), "/forbidden": (b"nope", 403, {}), "/limited": (b"slow", 429, {}),
                 "/moved": (b"", 302, {"Location": "/blocked"}),
                 "/html": (b"<html>checking your browser</html>", 200, {}),
                 "/page": (b"<html>captcha in a contact form, timetable</html>", 200, {}),
                 "/challenge": (b"<html><title>Just a moment...</title></html>", 200, {}),
                 "/cf": (b"<html>Just a moment... cloudflare</html>", 503, {})}
        body, code, hdr = table.get(p, (b"missing", 404, {}))
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

    def test_html_challenge_page_is_a_ban_but_the_word_captcha_is_not(self):
        g = self.g()
        guard_mod.fetch(g, "rt", self.base + "/page", UA, expect="html")
        self.assertFalse(g.breaker_open())
        with self.assertRaises(Blocked):
            guard_mod.fetch(g, "rt", self.base + "/challenge", UA, expect="html")
        self.assertTrue(g.breaker_open())

    def test_plain_404_is_an_error_not_a_ban(self):
        g = self.g()
        with self.assertRaises(SourceError):
            guard_mod.fetch(g, "rt", self.base + "/gone", UA)
        self.assertFalse(g.breaker_open())
        self.assertEqual(g.errors, 1)

    def test_soft_404_returns_status(self):
        g = self.g()
        status, _, _ = guard_mod.fetch(g, "rt", self.base + "/gone", UA, soft_404=True)
        self.assertEqual(status, 404)
        self.assertEqual(g.errors, 0)


class ClientTests(unittest.TestCase):
    def test_kp_parsers(self):
        s = FixtureKp()
        self.assertEqual(s.stops_revision(), 9885)
        stops = s.stops(9885)
        self.assertEqual(stops["622548"]["station"], True)
        self.assertEqual(s.trip(38155603, 17)["line"]["name"], "151")
        self.assertEqual(len(s.departures([BLACH, "622548"])["departures"]), 2)
        self.assertEqual(s.trip_execution("151:739910:4", 17)["vehicle_trip_index"], 9)
        self.assertTrue(s.paths[-1].startswith("/api/trip_execution/MTUxOjczOTkxMDo0/"))

    def test_line_known_uses_the_urlsafe_line_key_and_reads_404_as_unknown(self):
        real = client.Source(None, "http://x", UA)
        seen = []

        def fake(guard, lane, url, ua, **kw):
            seen.append(url)
            assert kw.get("soft_404")
            if url.split("/")[-1].startswith("OTk5"):
                return 404, {}, b"<html>404</html>"
            return 200, {}, fx("kp_timetable_line_151.json", raw=True)

        with mock.patch.object(client, "fetch", fake):
            self.assertTrue(real.line_known(BLACH, "151", "2026-10-21"))
            self.assertFalse(real.line_known(BLACH, "999", "2026-10-21"))
        self.assertTrue(seen[0].endswith("/api/timetable/2303517:2391682/MTUx?date=2026-10-21"))

    def test_shape_errors(self):
        s = FixtureKp()
        s._get = lambda lane, path, **kw: b'{"nothing": 1}'
        for f in (lambda: s.stops(1), lambda: s.trip(1, 1), lambda: s.departures([BLACH])):
            with self.assertRaises(SourceError):
                f()

    def test_op_source_rejects_pages_without_timetable(self):
        op = FixtureOp()
        op._page = lambda path: "<html>Brak strony</html>"
        with self.assertRaises(SourceError):
            op.lines()
        with self.assertRaises(SourceError):
            op.line_page("linia-nr-1-i1.html")


class OperatorParserTests(unittest.TestCase):
    def test_home(self):
        self.assertEqual([x for x, _ in opsite.parse_home(op_page("home.html"))], ["151", "102", "131", "141", "123B"])

    def test_line_151(self):
        p = opsite.parse_line(op_page("linia-nr-151-i223.html"))
        self.assertEqual((p["valid_from"], p["valid_to"]), ("2026-03-01", "2026-12-31"))
        self.assertEqual(p["reverse_url"], "linia-nr-151-i224.html")
        self.assertEqual([d["id"] for d in p["directions"]], ["tam", "powrot"])
        tam = p["directions"][0]
        self.assertEqual(len(tam["stops"]), 37)
        self.assertEqual(tam["stops"][0], "Częstochowa Dworzec Autobusowy")
        days = [c["day"] for c in tam["courses"]]
        self.assertEqual((days.count("wd"), days.count("sa"), days.count("su")), (13, 9, 9))
        c1 = tam["courses"][0]
        self.assertEqual((c1["times"][0], c1["times"][1]), (5 * 60 + 30, 5 * 60 + 31))
        self.assertEqual(p["markers"][0][3], 1674)
        self.assertEqual(p["problems"], [])

    def test_symbols_and_not_calling_cells(self):
        p = opsite.parse_line(op_page("linia-nr-102-i265.html"))
        self.assertEqual(p["legend"]["q"], "kurs do przystanku Pająk Zalew następnie Jamki łącznik")
        courses = [c for d in p["directions"] for c in d["courses"]]
        self.assertTrue(any("q" in c["sym"] for c in courses))
        self.assertTrue(any("S" in c["sym"] for c in courses))
        self.assertTrue(any(None in c["times"] for c in courses))  # the "<<" cells
        self.assertEqual(p["problems"], [])

    def test_short_rows_are_flagged_not_hidden(self):
        p = opsite.parse_line(op_page("linia-nr-141-i90.html"))
        self.assertTrue(any("cells vs" in x for x in p["problems"]))

    def test_one_way_line(self):
        p = opsite.parse_line(op_page("linia-nr-131-i256.html"))
        self.assertIsNone(p["reverse_url"])
        rec = opsite.line_record(p, None, ("linia-nr-131-i256.html", None), NOW)
        self.assertEqual((rec["crosscheck"], list(rec["dirs"])), ("one-way", ["A"]))

    def test_line_record_crosschecks_both_pages_and_takes_ids_from_each(self):
        main = opsite.parse_line(op_page("linia-nr-151-i223.html"))
        rev = opsite.parse_line(op_page("linia-nr-151-i224.html"))
        rec = opsite.line_record(main, rev, ("a", "b"), NOW)
        self.assertEqual(rec["crosscheck"], "ok")
        self.assertTrue(all(s["id"] is not None and s["lat"] is not None for d in rec["dirs"].values()
                            for s in d["stops"]))
        self.assertNotEqual(rec["dirs"]["A"]["stops"][0]["id"], rec["dirs"]["B"]["stops"][0]["id"])

    def test_norm_matches_across_sources(self):
        self.assertEqual(opsite.norm("Częstochowa Dworzec Autobusowy"), opsite.norm("Częstochowa, Dworzec Autobusowy"))
        self.assertEqual(opsite.norm("Łyszkowice"), "lyszkowice")


class CalendarTests(unittest.TestCase):
    def test_easter_and_holidays(self):
        self.assertEqual(calpl.easter(2026), date(2026, 4, 5))
        self.assertEqual(calpl.easter(2025), date(2025, 4, 20))
        h = calpl.holidays(2026)
        for d in (date(2026, 4, 6), date(2026, 5, 24), date(2026, 6, 4), date(2026, 11, 11), date(2026, 12, 24)):
            self.assertIn(d, h)
        self.assertNotIn(date(2024, 12, 24), calpl.holidays(2024))

    def test_day_type(self):
        self.assertEqual(calpl.day_type(date(2026, 10, 21)), "wd")
        self.assertEqual(calpl.day_type(date(2026, 10, 24)), "sa")
        self.assertEqual(calpl.day_type(date(2026, 11, 1)), "su")
        self.assertEqual(calpl.day_type(date(2026, 11, 11)), "su")  # Wednesday, public holiday


class CrawlTests(unittest.TestCase):
    def test_full_crawl_request_counts(self):
        with tempfile.TemporaryDirectory() as d:
            _, kp, op, store, c = crawled(d)
            s = store.s
            self.assertEqual(sorted(s["lines"]), sorted(LINES))
            # 1 start page, 5 first pages, 4 reverse pages (131 is one-way)
            self.assertEqual(len(op.paths), 10)
            self.assertEqual(kp.paths[:2], ["/", "/stops?rev=9885"])
            self.assertEqual(len([p for p in kp.paths if p.startswith("census")]), CENSUS_REQUESTS)
            self.assertIsNone(c.step())
            self.assertEqual(s["kp_lines"]["151"]["known"], True)
            self.assertEqual(s["kp_lines"]["131"]["known"], False)

    def test_each_step_is_at_most_one_request(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = tmp_cfg()
            kp, op, store = FixtureKp(), FixtureOp(), Store(os.path.join(d, "state.json"))
            c = crawl.Crawler(cfg, store, kp, op, clock=lambda: NOW)
            while True:
                before = len(kp.paths) + len(op.paths)
                if not c.step():
                    break
                made = len(kp.paths) + len(op.paths) - before
                self.assertEqual(made, 2 if c.stats["last_job"] == "kp-stops" else 1)  # that job reads the start page, then /stops

    def test_line_pages_are_refetched_only_when_stale(self):
        with tempfile.TemporaryDirectory() as d:
            cfg, kp, op, store, c = crawled(d)
            n = len(op.paths)
            c.clock = lambda: NOW + 86400
            self.assertEqual(c.step(), "home")  # daily list check
            self.assertEqual(c.step(), "kp-stops")  # daily stop list revision check
            self.assertIsNone(c.step())
            self.assertEqual(len(op.paths), n + 1)
            c.clock = lambda: NOW + 86400 * 4
            self.assertEqual(c.step(), "home")
            jobs = []
            while True:
                j = c.step()
                if not j:
                    break
                jobs.append(j)
            self.assertIn("line", jobs)

    def test_failed_line_page_is_not_fatal_and_retried_later(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = tmp_cfg()
            op = FixtureOp()
            orig = op.line_page
            op.line_page = lambda url: (_ for _ in ()).throw(SourceError("HTTP 500")) if "102" in url else orig(url)
            store = Store(os.path.join(d, "state.json"))
            c = crawl.Crawler(cfg, store, FixtureKp(), op, clock=lambda: NOW)
            while c.step():
                pass
            self.assertNotIn("102", store.s["lines"])
            self.assertEqual(len(store.s["lines"]), 4)
            self.assertIn("fail", store.s["line_fetch"]["102"])


class GtfsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        _, _, _, cls.store, _ = crawled(cls.tmp)
        s = cls.store.s
        cls.data, cls.stats = gtfs.build(cls.store, NOW, s["kp_stops"], s["kp_lines"], len(s["site_lines"]))
        cls.idx = gtfs.Index(cls.data)

    def test_content_and_table(self):
        st = self.stats
        self.assertEqual((st["lines_on_site"], st["lines_with_trips"], st["line_coverage_percent"]), (5, 5, 100))
        self.assertEqual({r["line"] for r in st["lines"]}, set(LINES))
        self.assertEqual(sum(r["trips"] for r in st["lines"]), st["trips"])
        self.assertEqual(set(self.idx.routes), {"line-" + x for x in LINES})
        r151 = next(r for r in st["lines"] if r["line"] == "151")
        self.assertEqual((r151["trips"], r151["stops"], r151["kp_known"], r151["status"]), (62, 71, True, "ok"))

    def test_ids_and_sequences(self):
        t = self.idx.times["151-A-wd-0530"]
        self.assertEqual(min(t), 0)
        self.assertEqual(t[0][1], 5 * 3600 + 30 * 60)
        self.assertEqual(self.idx.trips["151-A-wd-0530"]["trip_headsign"], "Węglowice Szkoła")
        self.assertTrue(self.idx.trips["151-A-wd-0530"]["service_id"].startswith("wd-20260301-20261231"))

    def test_calendar_and_holidays(self):
        t = "151-A-wd-0530"
        self.assertTrue(self.idx.active(t, "20261021"))
        self.assertFalse(self.idx.active(t, "20261024"))  # Saturday
        self.assertFalse(self.idx.active(t, "20261111"))  # Wednesday, public holiday
        su = "151-A-su-0520"
        self.assertTrue(self.idx.active(su, "20261111"))
        self.assertTrue(self.idx.active(su, "20261025"))
        self.assertFalse(self.idx.active(su, "20261021"))
        self.assertFalse(self.idx.active(t, "20270105"))  # after validity

    def test_school_day_marker_is_kept(self):
        marked = [t for t in self.idx.trips.values() if t["trip_short_name"]]
        self.assertTrue(any("S" in t["trip_short_name"].split(",") for t in marked))
        self.assertTrue(any(t["trip_short_name"] == "q" or "q" in t["trip_short_name"] for t in marked))

    def test_stops_have_operator_positions(self):
        self.assertTrue(all(float(r["stop_lat"]) and float(r["stop_lon"]) for r in self.idx.stops.values()))
        self.assertIn("1674", self.idx.stops)

    def test_deterministic(self):
        s = self.store.s
        again, _ = gtfs.build(self.store, NOW, s["kp_stops"], s["kp_lines"], 5)
        self.assertEqual(again, self.data)

    def test_expired_timetable_is_reported_not_published(self):
        s = self.store.s
        data, stats = gtfs.build(self.store, NOW + 86400 * 400, s["kp_stops"], s["kp_lines"], 5)
        self.assertIsNone(data)

    def test_operator_marker_far_from_every_same_name_stop_uses_the_kp_position(self):
        store = Store(os.path.join(self.tmp, "moved.json"))
        store.s = json.loads(json.dumps(self.store.s))
        st = store.s["lines"]["151"]["dirs"]["A"]["stops"][0]  # Częstochowa Dworzec Autobusowy, has a kp twin
        st["lat"] += 0.05
        sid = str(st["id"])
        data, stats = gtfs.build(store, NOW, store.s["kp_stops"], {}, 5)
        self.assertEqual(list(stats["position_overrides"]), [sid])
        row = gtfs.Index(data).stops[sid]
        self.assertAlmostEqual(float(row["stop_lat"]), 50.806291, places=3)
        self.assertIn("kiedyPrzyjedzie", row["stop_desc"])
        self.assertEqual(gtfs.Index(self.data).stops[sid]["stop_desc"], "")

    def test_unresolvable_stop_is_dropped_and_counted(self):
        store = Store(os.path.join(self.tmp, "other.json"))
        store.s = json.loads(json.dumps(self.store.s))
        st = store.s["lines"]["131"]["dirs"]["A"]["stops"][2]
        st.update(id=None, lat=None, lon=None, name="Nigdzie Nieznane")
        _, stats = gtfs.build(store, NOW, {}, {}, 5)
        row = next(r for r in stats["lines"] if r["line"] == "131")
        self.assertEqual(row["dropped_stops"], 1)


class ReconTests(unittest.TestCase):
    def test_positions_compared_by_name(self):
        s = crawled(tempfile.mkdtemp())[3].s
        op_stops, _ = gtfs.stop_table(s["lines"])
        r = recon.compare(op_stops, s["kp_stops"])
        self.assertEqual(r["op_stops"], len(op_stops))
        self.assertEqual(r["within_30m"] + r["30_to_100m"] + len(r["over_100m"]) + len(r["op_only"]), len(op_stops))
        self.assertGreater(r["within_30m"], 0)

    def test_metres_and_buckets(self):
        self.assertAlmostEqual(recon.metres((50.0, 19.0), (50.0, 19.001)), 71.5, delta=1)
        names = recon.by_name({"k1": {"name": "Rynek", "lat": 50.0, "lon": 19.0}})
        far = {"name": "Rynek", "lat": 50.0, "lon": 19.01}
        self.assertGreater(recon.nearest_kp(far, names)[0], 100)
        self.assertIsNone(recon.nearest_kp({"name": "Inny", "lat": 50.0, "lon": 19.0}, names))


class RtTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        _, _, _, self.store, _ = crawled(self.tmp)
        s = self.store.s
        data, _ = gtfs.build(self.store, NOW, s["kp_stops"], s["kp_lines"], 5)
        self.idx = gtfs.Index(data)
        self.rt = Rt(s["map"])
        self.rt.set_static(self.idx, s["kp_stops"])
        self.kp = FixtureKp()

    def feed(self, which, now=NOW_DEP + 5):
        f = pb.FeedMessage()
        f.ParseFromString(self.rt.build(now)[which])
        return f

    def mapped(self):
        resp = self.kp.departures([BLACH, "622548"])
        cands, need = self.rt.ingest_departures(resp, NOW_DEP)
        for ktid, kidx, dt in sorted(need):
            if os.path.exists(os.path.join(FX, "trips", f"{ktid}.json")):
                self.rt.map_trip(ktid, self.kp.trip(ktid, kidx), dt, NOW_DEP)
        return resp

    def test_not_ready_before_first_poll(self):
        self.assertIsNone(self.rt.build(NOW))

    def test_live_trip_is_mapped_by_content_and_cached(self):
        resp = self.kp.departures([BLACH])
        _, need = self.rt.ingest_departures(resp, NOW_DEP)
        self.assertIn(("38155603", 17, "wd"), need)
        e = self.rt.map_trip("38155603", self.kp.trip(38155603, 17), "wd", NOW_DEP)
        self.assertEqual(e["op"], "151-B-wd-0830")
        self.assertEqual(len(e["seq"]), 36)
        self.assertIn("38155603|wd", self.store.s["map"])
        _, need = self.rt.ingest_departures(resp, NOW_DEP)
        self.assertNotIn(("38155603", 17, "wd"), need)

    def test_delay_attaches_to_operator_ids(self):
        self.mapped()
        cands, _ = self.rt.ingest_departures(self.kp.departures([BLACH]), NOW_DEP)
        tu = self.feed(0)
        self.assertEqual(tu.header.incrementality, pb.FeedHeader.FULL_DATASET)
        self.assertEqual(tu.header.timestamp, NOW_DEP)
        ents = {e.trip_update.trip.trip_id: e.trip_update for e in tu.entity}
        u = ents["151-B-wd-0830"]
        self.assertEqual((u.trip.start_date, u.trip.route_id), ("20261021", "line-151"))
        self.assertEqual(u.stop_time_update[0].departure.delay, 120)
        seq = u.stop_time_update[0].stop_sequence
        self.assertEqual(self.idx.stop_at("151-B-wd-0830", seq), u.stop_time_update[0].stop_id)
        self.assertEqual(self.idx.stops[u.stop_time_update[0].stop_id]["stop_name"][:11], "Blachownia,")
        self.assertEqual(cands[0][1:4], ("38155603", 17, "151:739910:4"))
        self.assertNotIn("37634158", [e.trip_update.trip.trip_id for e in tu.entity])

    def test_unmapped_rows_are_counted_not_guessed(self):
        self.rt.ingest_departures(self.kp.departures([BLACH, "622548"]), NOW_DEP)
        r = self.rt.stats["unmatched_reasons"]
        self.assertEqual(r["no operator trip matched (yet)"], self.rt.stats["rows_unmatched"])
        self.assertEqual(len(self.feed(0).entity), 0)

    def test_execution_gives_vehicle_and_stop_delays(self):
        self.mapped()
        self.rt.ingest_departures(self.kp.departures([BLACH]), NOW_DEP)
        ok = self.rt.ingest_execution("38155603", "151-B-wd-0830", "20261021",
                                      self.kp.trip_execution("151:739910:4", 17), NOW_DEP)
        self.assertTrue(ok)
        v = self.feed(1).entity[0].vehicle
        self.assertEqual((v.trip.trip_id, v.trip.start_date, v.trip.route_id), ("151-B-wd-0830", "20261021", "line-151"))
        self.assertEqual(v.current_status, pb.VehiclePosition.IN_TRANSIT_TO)
        self.assertEqual(v.stop_id, self.idx.stop_at("151-B-wd-0830", v.current_stop_sequence))
        tu = [e.trip_update for e in self.feed(0).entity if e.trip_update.trip.trip_id == "151-B-wd-0830"][0]
        seqs = [u.stop_sequence for u in tu.stop_time_update]
        self.assertEqual(seqs, sorted(set(seqs)))
        self.assertTrue(all(u.stop_id == self.idx.stop_at("151-B-wd-0830", u.stop_sequence) for u in tu.stop_time_update))
        self.assertTrue(all(u.arrival.delay == 0 for u in tu.stop_time_update if u.stop_sequence >= v.current_stop_sequence))

    def test_execution_for_unmapped_trip_is_refused(self):
        self.assertFalse(self.rt.ingest_execution("38155603", "151-B-wd-0830", "20261021",
                                                  self.kp.trip_execution("151:739910:4", 17), NOW_DEP))

    def test_ambiguity_gives_no_match(self):
        raw = self.kp.trip(38155603, 17)
        raw["line"]["name"] = "no-such-line"
        self.assertIsNone(self.rt.map_trip("zz", raw, "wd", NOW)["op"])

    def test_entries_expire(self):
        self.mapped()
        self.rt.ingest_departures(self.kp.departures([BLACH]), NOW_DEP)
        self.assertGreater(len(self.feed(0).entity), 0)
        self.assertEqual(len(self.feed(0, now=NOW_DEP + 10_000).entity), 0)


class AppTests(unittest.TestCase):
    def mk(self):
        d = tempfile.mkdtemp()
        cfg = tmp_cfg()
        cfg["breaker"]["kill_file"] = os.path.join(d, "KILL")
        app = main_mod.App(cfg, d, clock=lambda: NOW_DEP)
        app.kp, app.op = FixtureKp(), FixtureOp()
        app.crawler = crawl.Crawler(cfg, app.store, app.kp, app.op, clock=lambda: NOW)
        return app

    def test_quiet_hours(self):
        self.assertTrue(main_mod.in_quiet(1792618800, "23:30", "04:00"))
        self.assertFalse(main_mod.in_quiet(NOW, "23:30", "04:00"))

    def test_health_down_then_ok_with_per_line_table(self):
        app = self.mk()
        self.assertEqual(app.health()["status"], "down")
        while app.crawler.step():
            pass
        app.clock = lambda: NOW
        app.rebuild()
        app.clock = lambda: NOW_DEP
        h = app.health()
        self.assertEqual(h["status"], "ok")
        st = h["static"]
        self.assertEqual((st["lines_on_site"], st["lines_with_trips"]), (5, 5))
        row = next(r for r in st["lines"] if r["line"] == "151")
        self.assertEqual((row["trips"], row["stops"], row["kiedyprzyjedzie"]), (62, 71, True))
        self.assertIn("141", st["lines_missing_or_partial"])  # short rows in the source are reported
        self.assertGreater(st["positions"]["within_30m"], 0)

    def test_poll_cycle_budget_and_mapping(self):
        app = self.mk()
        while app.crawler.step():
            pass
        app.clock = lambda: NOW
        app.rebuild()
        app.clock = lambda: NOW_DEP
        app.kp.paths.clear()
        app.poll_once(NOW_DEP)
        kinds = [p.split("?")[0].split("/")[2] for p in app.kp.paths]
        self.assertEqual(kinds[0], "departures")
        self.assertIn("trip", kinds)  # one-off mapping calls
        self.assertLessEqual(kinds.count("trip"), CFG["realtime"]["map_per_cycle"])
        self.assertLessEqual(kinds.count("trip_execution"), 1)
        app.kp.paths.clear()
        app.poll_once(NOW_DEP)
        again = [p.split("?")[0].split("/")[2] for p in app.kp.paths]
        self.assertLess(again.count("trip"), kinds.count("trip") + 1)
        app.boost()
        self.assertEqual(app.mode(NOW_DEP), "boost")

    def test_http_endpoints(self):
        app = self.mk()
        while app.crawler.step():
            pass
        app.clock = lambda: NOW
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
            body = urllib.request.urlopen(base + "/health").read()
            self.assertIn(b'"breaker": "closed"', body)
        finally:
            srv.shutdown()


if __name__ == "__main__":
    unittest.main()
