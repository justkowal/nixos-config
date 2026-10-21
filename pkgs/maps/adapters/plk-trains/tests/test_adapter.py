import copy
import io
import json
import logging
import os
import sys
import tempfile
import tomllib
import unittest
import urllib.error
import zipfile
from datetime import date
from email.message import Message

HERE = os.path.dirname(__file__)
ROOT = os.path.join(HERE, "..")
sys.path.insert(0, os.path.join(ROOT, "src"))

from google.transit import gtfs_realtime_pb2 as pb  # noqa: E402

from plk_trains import gtfs, rt  # noqa: E402
from plk_trains.client import ApiError, Client, NoKey  # noqa: E402
from plk_trains.geocode import Geocoder  # noqa: E402
from plk_trains.limiter import WAW, Denied, Limiter, in_maintenance  # noqa: E402
from plk_trains.resolve import resolve  # noqa: E402
from plk_trains.schema import SchemaError, load_spec, validate  # noqa: E402

with open(os.path.join(ROOT, "config.toml"), "rb") as f:
    CFG = tomllib.load(f)
SPEC = load_spec()
TODAY = date(2026, 10, 21)
SECRET = "sk_live_SENTINEL_DO_NOT_LOG"


def fx(name):
    with open(os.path.join(HERE, "fixtures", name + ".json"), encoding="utf8") as f:
        return json.load(f)


class FakeClock:
    def __init__(self, t=1_792_000_000.0):  # 2026-10-14 ish, a Wednesday
        self.t = t

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.t += s


def make_geocoder(tmp):
    nom = fx("nominatim")
    clock = FakeClock()
    return Geocoder(CFG, os.path.join(tmp, "geo.json"), os.path.join(tmp, "ov.json"),
                    fetch=lambda name: nom.get(name, []), clock=clock, sleep=clock.sleep)


def build_static(tmp):
    return gtfs.build([fx("schedules_down"), fx("schedules_up")], make_geocoder(tmp), TODAY, CFG,
                      "22222222-2222-2222-2222-222222222222")


class SchemaTests(unittest.TestCase):
    def test_fixtures_validate(self):
        for fixture, schema in (("schedules_down", "ScheduleResponseDto"), ("schedules_up", "ScheduleResponseDto"),
                                ("operations", "OperationResponseDto"), ("disruptions", "DisruptionResponseDto"),
                                ("data_version", "DataVersionResponse"), ("stations", "StationsResponse"),
                                ("carriers", "CarriersResponse")):
            validate(SPEC, schema, fx(fixture))

    def test_type_change_fails(self):
        d = fx("schedules_down")
        d["routes"][0]["orderId"] = "111111"
        with self.assertRaises(SchemaError):
            validate(SPEC, "ScheduleResponseDto", d)

    def test_missing_required_fails(self):
        d = fx("operations")
        del d["trains"]
        with self.assertRaises(SchemaError):
            validate(SPEC, "OperationResponseDto", d)

    def test_bad_duration_fails(self):
        d = fx("schedules_down")
        d["routes"][0]["stations"][0]["departureTime"] = "8am"
        with self.assertRaises(SchemaError):
            validate(SPEC, "ScheduleResponseDto", d)

    def test_extra_field_tolerated(self):
        d = fx("operations")
        d["brandNewField"] = 1
        validate(SPEC, "OperationResponseDto", d)


class StaticTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def files(self, blob):
        z = zipfile.ZipFile(io.BytesIO(blob))
        return {n: z.read(n).decode().splitlines() for n in z.namelist()}

    def test_build(self):
        blob, index, stats = build_static(self.tmp)
        f = self.files(blob)
        for n in ("agency.txt", "stops.txt", "routes.txt", "trips.txt", "stop_times.txt",
                  "calendar_dates.txt", "feed_info.txt", "attributions.txt", "license.txt"):
            self.assertIn(n, f)
        self.assertEqual(stats["trips"], 4)
        self.assertEqual(sorted(index["trips"]), ["26-111111", "26-111112", "26-222222", "26-333333-333334"])
        self.assertIn("26-222222,24:10:00,24:11:00,900003,3", f["stop_times.txt"])
        # pass-through stop dropped
        self.assertEqual(index["trips"]["26-333333-333334"]["stops"], ["900001", "900004"])
        self.assertTrue(any("derived" in x.lower() or "OpenStreetMap" in x for x in f["stops.txt"]))
        self.assertEqual(stats["osm_positions"], 4)

    def test_stable_and_deterministic(self):
        a = build_static(self.tmp)
        b = build_static(self.tmp)
        self.assertEqual(a[0], b[0])
        self.assertEqual(a[1], b[1])

    def test_past_dates_dropped(self):
        _, index, _ = build_static(self.tmp)
        self.assertNotIn("20261019", index["trips"]["26-111111"]["dates"])
        self.assertIn("20261020", index["trips"]["26-111111"]["dates"])

    def test_non_monotonic_trip_dropped(self):
        down = fx("schedules_down")
        down["routes"][1]["stations"][2]["arrivalDay"] = 0
        down["routes"][1]["stations"][2]["departureDay"] = 0
        _, index, stats = gtfs.build([down], make_geocoder(self.tmp), TODAY, CFG, "x" * 36)
        self.assertNotIn("26-222222", index["trips"])
        self.assertEqual(stats["dropped"]["non_monotonic_times"], 1)

    def test_override_wins_and_missing_geocode_drops_stop(self):
        with open(os.path.join(self.tmp, "ov.json"), "w") as f:
            json.dump({"900002": [50.1, 20.1]}, f)
        g = make_geocoder(self.tmp)
        g.fetch = lambda name: []
        with self.assertRaises(ValueError):  # every trip is left with fewer than 2 located stops
            gtfs.build([fx("schedules_down")], g, TODAY, CFG, "x" * 36)


class RealtimeTests(unittest.TestCase):
    def setUp(self):
        self.index = build_static(tempfile.mkdtemp())[1]
        blob, self.stats = rt.build_trip_updates(fx("operations")["trains"], self.index, 1_792_000_000)
        self.feed = pb.FeedMessage()
        self.feed.ParseFromString(blob)
        self.by_id = {e.id: e.trip_update for e in self.feed.entity}

    def test_header(self):
        self.assertEqual(self.feed.header.incrementality, pb.FeedHeader.FULL_DATASET)
        self.assertEqual(self.feed.header.timestamp, 1_792_000_000)
        self.assertEqual(self.feed.header.gtfs_realtime_version, "2.0")

    def test_matching_and_counts(self):
        self.assertEqual(self.stats["unmatched"], 2)  # unknown order, date outside service
        self.assertEqual(sorted(self.by_id), ["26-111111_20261021", "26-222222_20261020", "26-333333-333334_20261021"])

    def test_delays_attach_to_right_trip_and_stop(self):
        tu = self.by_id["26-111111_20261021"]
        self.assertEqual(tu.trip.trip_id, "26-111111")
        self.assertEqual(tu.trip.start_date, "20261021")
        ups = {u.stop_id: u for u in tu.stop_time_update}
        self.assertEqual(ups["900001"].departure.delay, 240)
        self.assertFalse(ups["900001"].HasField("arrival"))
        self.assertEqual(ups["900002"].arrival.delay, 300)
        self.assertNotIn("900003", ups)  # no data for the stop: nothing invented
        # every stop id exists in the static trip
        self.assertTrue(set(ups) <= set(self.index["trips"]["26-111111"]["stops"]))

    def test_cancellation_and_skipped_stop(self):
        self.assertEqual(self.by_id["26-222222_20261020"].trip.schedule_relationship, pb.TripDescriptor.CANCELED)
        tu = self.by_id["26-333333-333334_20261021"]
        self.assertEqual(tu.trip.schedule_relationship, pb.TripDescriptor.SCHEDULED)
        # 900002 is not a stop of the trimmed static trip (pass-through), so its skip is not emitted
        self.assertEqual([u.stop_id for u in tu.stop_time_update], ["900001"])

    def test_alerts_only_for_matched_trips(self):
        blob, st = rt.build_alerts(fx("disruptions"), self.index, 1_792_000_000)
        feed = pb.FeedMessage()
        feed.ParseFromString(blob)
        self.assertEqual(st, {"disruptions": 2, "published": 1, "unmatched": 1})
        a = feed.entity[0].alert
        self.assertEqual(a.informed_entity[0].trip.trip_id, "26-111111")
        self.assertEqual(a.header_text.translation[0].language, "pl")


class FakeResp:
    def __init__(self, status, body, headers):
        self.status, self._b, self.headers = status, body, headers

    def read(self, n=-1):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def hdrs(**kw):
    m = Message()
    for k, v in kw.items():
        m[k.replace("_", "-")] = str(v)
    return m


class FakeOpener:
    def __init__(self, script):
        self.script, self.calls = list(script), []

    def open(self, req, timeout=None):
        self.calls.append(req)
        item = self.script.pop(0)
        if isinstance(item, Exception):
            raise item
        status, body, h = item
        if status != 200:
            raise urllib.error.HTTPError(req.full_url, status, "x", h, io.BytesIO(body))
        return FakeResp(status, body, h)


def ok(obj, **h):
    h.setdefault("Content_Type", "application/json")
    return 200, json.dumps(obj).encode(), hdrs(**h)


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.keyfile = os.path.join(self.tmp, "key")
        with open(self.keyfile, "w") as f:
            f.write(SECRET + "\n")
        self.cfg = copy.deepcopy(CFG)
        self.cfg["api"]["key_file"] = self.keyfile
        self.clock = FakeClock()
        self.lim = Limiter(self.cfg, os.path.join(self.tmp, "lim.json"), os.path.join(self.tmp, "KILL"),
                           clock=self.clock, sleep=self.clock.sleep, rand=lambda a, b: 0)

    def client(self, script):
        self.op = FakeOpener(script)
        return Client(self.cfg, self.lim, SPEC, opener=self.op)

    def test_headers_and_no_key_in_url_or_logs(self):
        c = self.client([ok(fx("data_version"), X_RateLimit_Hourly_Limit=100, X_RateLimit_Daily_Limit=1000,
                            X_RateLimit_Hourly_Remaining=99, X_RateLimit_Daily_Remaining=999)])
        with self.assertLogs(level="DEBUG") as cap:
            logging.getLogger("plk.client").info("probe")
            c.get("/api/v1/data-version", None, "DataVersionResponse")
        req = self.op.calls[0]
        self.assertEqual(req.get_header("X-api-key"), SECRET)
        self.assertNotIn(SECRET, req.full_url)
        self.assertIn("kowal-lab-maps-adapter/0.1 (personal use; contact hopkuba@gmail.com)",
                      req.get_header("User-agent"))
        self.assertEqual(req.get_header("X-api-version"), "1.0")
        self.assertNotIn(SECRET, "\n".join(cap.output))
        self.assertEqual(self.lim.tier, "Basic")
        self.assertEqual(self.lim.remaining["daily"], 999)
        self.assertEqual(self.lim.caps(), (60, 700))

    def test_missing_key(self):
        os.remove(self.keyfile)
        with self.assertRaises(NoKey):
            self.client([]).get("/x")

    def test_spacing_enforced(self):
        c = self.client([ok(fx("data_version")), ok(fx("data_version"))])
        c.get("/a", None, "DataVersionResponse")
        t = self.clock.t
        c.get("/b", None, "DataVersionResponse")
        self.assertGreaterEqual(self.clock.t - t, 3.0)

    def test_429_pauses_not_breaker(self):
        c = self.client([(429, b"{}", hdrs(X_RateLimit_Hourly_Remaining=0, X_RateLimit_Daily_Remaining=500))])
        with self.assertRaises(ApiError):
            c.get("/a")
        self.assertGreater(self.lim.pause_until, self.clock.t)
        self.assertLess(self.lim.pause_until - self.clock.t, 3700)
        self.assertEqual(self.lim.breaker_until, 0)
        with self.assertRaises(Denied):
            self.lim.acquire()

    def test_429_daily_pauses_to_next_day(self):
        c = self.client([(429, b"{}", hdrs(X_RateLimit_Hourly_Remaining=50, X_RateLimit_Daily_Remaining=0))])
        with self.assertRaises(ApiError):
            c.get("/a")
        self.assertGreater(self.lim.pause_until - self.clock.t, 3700)
        self.assertEqual(self.lim.breaker_until, 0)

    def test_403_opens_breaker_for_6h(self):
        c = self.client([(403, b"no", hdrs())])
        with self.assertRaises(ApiError):
            c.get("/a")
        self.assertAlmostEqual(self.lim.breaker_until - self.clock.t, 6 * 3600, delta=5)
        with self.assertRaises(Denied):
            self.lim.acquire()

    def test_redirect_and_html_open_breaker(self):
        c = self.client([(302, b"", hdrs(Location="https://block.example/"))])
        with self.assertRaises(ApiError):
            c.get("/a")
        self.assertGreater(self.lim.breaker_until, self.clock.t)
        self.lim.breaker_until = 0
        self.clock.t += 10
        c = self.client([(200, b"<html>challenge</html>", hdrs(Content_Type="text/html"))])
        with self.assertRaises(ApiError):
            c.get("/a")
        self.assertGreater(self.lim.breaker_until, self.clock.t)

    def test_error_run_backoff_then_breaker(self):
        c = self.client([(500, b"", hdrs())] * 5)
        waits = []
        for _ in range(5):
            self.clock.t = max(self.clock.t, self.lim.backoff_until) + 1
            with self.assertRaises(ApiError):
                c.get("/a")
            waits.append(round(self.lim.backoff_until - self.clock.t))
        self.assertEqual(waits[:3], [30, 60, 120])
        self.assertGreater(self.lim.breaker_until, self.clock.t)

    def test_own_budget_and_reserve(self):
        self.lim.limits = {"hourly": 100, "daily": 1000}
        self.lim.stamps = [self.clock.t - 10] * 60
        with self.assertRaises(Denied):
            self.lim.check("rt")
        self.lim.check("static")  # static may use up to 90 percent
        self.lim.stamps = []
        self.lim.remaining = {"hourly": 39, "daily": 900, "ts": self.clock.t}
        with self.assertRaises(Denied):
            self.lim.check("rt")
        self.lim.check("static")
        self.lim.remaining = {"hourly": 90, "daily": 299, "ts": self.clock.t}
        with self.assertRaises(Denied):
            self.lim.check("rt")

    def test_kill_switch(self):
        open(os.path.join(self.tmp, "KILL"), "w").close()
        with self.assertRaises(Denied):
            self.client([]).get("/a")

    def test_schema_failure_raises(self):
        bad = fx("data_version")
        bad["schedulesVersion"] = 5
        with self.assertRaises(SchemaError):
            self.client([ok(bad)]).get("/a", None, "DataVersionResponse")

    def test_state_persists(self):
        self.client([(403, b"", hdrs())])
        c = self.client([(403, b"", hdrs())])
        with self.assertRaises(ApiError):
            c.get("/a")
        lim2 = Limiter(self.cfg, os.path.join(self.tmp, "lim.json"), clock=self.clock)
        self.assertEqual(lim2.breaker_until, self.lim.breaker_until)

    def test_maintenance_window(self):
        from datetime import datetime
        t = datetime(2026, 11, 3, 21, 0, tzinfo=WAW).timestamp()  # first Tuesday of November
        self.assertIsNotNone(in_maintenance(t, 15))
        t2 = datetime(2026, 11, 10, 21, 0, tzinfo=WAW).timestamp()
        self.assertIsNone(in_maintenance(t2, 15))


class ResolveGeocodeTests(unittest.TestCase):
    def test_resolve_with_one_request_and_cache(self):
        tmp = tempfile.mkdtemp()
        keyfile = os.path.join(tmp, "key")
        open(keyfile, "w").write("TESTKEY_" + "x" * 24)
        cfg = copy.deepcopy(CFG)
        cfg["api"]["key_file"] = keyfile
        cfg["corridor"]["pairs"] = [{"from": ["kraków  główny"], "to": ["Częstochowa", "Nigdzie"]}]
        clock = FakeClock()
        lim = Limiter(cfg, os.path.join(tmp, "l.json"), clock=clock, sleep=clock.sleep, rand=lambda a, b: 0)
        op = FakeOpener([ok(fx("stations"))])
        res = resolve(Client(cfg, lim, SPEC, opener=op), cfg, os.path.join(tmp, "r.json"), clock)
        self.assertEqual(res["pairs"], [{"from": [900001], "to": [900004]}])
        self.assertEqual(res["unresolved"], ["Nigdzie"])
        res2 = resolve(Client(cfg, lim, SPEC, opener=FakeOpener([])), cfg, os.path.join(tmp, "r.json"), clock)
        self.assertEqual(res2["pairs"], res["pairs"])
        self.assertEqual(len(op.calls), 1)

    def test_geocode_picks_station_not_building(self):
        g = make_geocoder(tempfile.mkdtemp())
        lat, lon, src = g.locate(900001, "Kraków Główny")
        self.assertAlmostEqual(lat, 50.0679)
        self.assertEqual(src, "osm-nominatim")


class AppFlowTests(unittest.TestCase):
    def test_static_then_realtime_then_health(self):
        from datetime import datetime

        from plk_trains.app import App
        tmp = tempfile.mkdtemp()
        keyfile = os.path.join(tmp, "key")
        with open(keyfile, "w") as f:
            f.write(SECRET)
        cfg = copy.deepcopy(CFG)
        cfg["api"]["key_file"] = keyfile
        cfg["paths"].update(data_dir=tmp, stop_overrides=os.path.join(tmp, "ov.json"),
                            kill_file=os.path.join(tmp, "KILL"))
        clock = FakeClock(datetime(2026, 10, 21, 10, 0, tzinfo=WAW).timestamp())
        lim = Limiter(cfg, os.path.join(tmp, "limiter.json"), clock=clock, sleep=clock.sleep,
                      rand=lambda a, b: 0)
        rl = dict(X_RateLimit_Hourly_Limit=500, X_RateLimit_Daily_Limit=5000,
                  X_RateLimit_Hourly_Remaining=490, X_RateLimit_Daily_Remaining=4900)
        op = FakeOpener([ok(fx("stations"), **rl), ok(fx("data_version"), **rl),
                         ok(fx("schedules_down"), **rl), ok(fx("schedules_up"), **rl),
                         ok(fx("operations"), X_Snapshot_Timestamp="2026-10-21T07:59:30Z", **rl),
                         ok(fx("disruptions"), **rl)])
        nom = fx("nominatim")
        geo = Geocoder(cfg, os.path.join(tmp, "geo.json"), cfg["paths"]["stop_overrides"],
                       fetch=lambda n: nom.get(n, []), clock=clock, sleep=clock.sleep)
        app = App(cfg, Client(cfg, lim, SPEC, opener=op), lim, geo, clock=clock, sleep=clock.sleep)
        app.static_cycle()
        self.assertEqual(len(op.calls), 4)
        self.assertIn("fromStations=900001", op.calls[2].full_url)
        self.assertIn("fromStations=900004", op.calls[3].full_url)
        self.assertNotIn(SECRET, "".join(r.full_url for r in op.calls))
        clock.t += 5
        app.poll_ops()
        app.poll_alerts()
        self.assertIn("stations=900001%2C900002", op.calls[4].full_url)
        self.assertIn("withPlanned=true", op.calls[4].full_url)
        h = app.health()
        self.assertEqual(h["status"], "ok")
        self.assertEqual(h["quota"]["tier"], "Standard")
        self.assertEqual(h["quota"]["caps"], {"hourly": 300, "daily": 3500})
        self.assertEqual(h["realtime"]["stats"]["matched"], 3)
        self.assertEqual(h["alerts"]["stats"]["published"], 1)
        self.assertEqual(h["resolved"]["unresolved"], ["Częstochowa Stradom"])
        self.assertNotIn(SECRET, json.dumps(h))
        self.assertTrue(os.path.exists(os.path.join(tmp, "out", "gtfs.zip")))
        # second cycle on the same day with unchanged version costs one request, no rebuild
        op.script.append(ok(fx("data_version"), **rl))
        clock.t += 10
        app.static_cycle()
        self.assertEqual(len(op.calls), 7)
        self.assertEqual(app.h["static"]["note"], "unchanged")

    def test_interval_spreads_budget(self):
        from datetime import datetime

        from plk_trains.app import App
        tmp = tempfile.mkdtemp()
        cfg = copy.deepcopy(CFG)
        cfg["paths"].update(data_dir=tmp, stop_overrides=os.path.join(tmp, "ov.json"),
                            kill_file=os.path.join(tmp, "KILL"))
        clock = FakeClock(datetime(2026, 10, 21, 4, 0, tzinfo=WAW).timestamp())
        lim = Limiter(cfg, os.path.join(tmp, "l.json"), clock=clock, sleep=clock.sleep)
        app = App(cfg, Client(cfg, lim, SPEC), lim, make_geocoder(tmp), clock=clock, sleep=clock.sleep)
        w = app.interval()  # Basic assumed: 700 cap, 20 h active, alerts take 40
        self.assertGreater(w, 90)
        self.assertLess(w, 130)
        lim.stamps = [clock.t - 100] * 690
        self.assertEqual(app.interval(), cfg["realtime"]["poll_max_s"])


if __name__ == "__main__":
    unittest.main()
