import json
import os
import sys
import tempfile
import time
import unittest

os.environ["NAV_SECRET"] = "unit-test-passphrase"
os.environ["NAV_DB"] = os.path.join(tempfile.mkdtemp(), "nav.db")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import server as s  # noqa: E402


class Tokens(unittest.TestCase):
    def test_roundtrip_and_device(self):
        self.assertEqual(s.session_device(s.make_cookie()), "web")
        self.assertEqual(s.session_device(s.make_cookie("pixel-8", 365)), "pixel-8")

    def test_tampering_and_expiry(self):
        t = s.make_cookie("web")
        exp, dev, sig = t.split(".", 2)
        self.assertIsNone(s.session_device(f"{exp}.other.{sig}"))
        self.assertIsNone(s.session_device(f"{exp}.{dev}.{'0' * 64}"))
        self.assertIsNone(s.session_device(s.make_cookie("web", -1)))
        self.assertIsNone(s.session_device("garbage"))


class Durations(unittest.TestCase):
    def test_iso(self):
        self.assertEqual([s.seconds(x) for x in ("PT0S", "PT3M20S", "-PT45S", "PT1H2M", None, 120)], [0, 200, -45, 3720, None, 120])

    def test_sane_rt_hides_wrong_day_updates(self):
        self.assertFalse(s.sane_rt(3600, 3600 + 90000, 90000, True)["realtime"])
        self.assertTrue(s.sane_rt(3600, 3720, 120, True)["realtime"])


class Validation(unittest.TestCase):
    def test_points_and_ids(self):
        self.assertEqual(s.point("50.06, 19.94", "x"), (50.06, 19.94))
        for bad in ("", "50,abc", "99999,1", "50.0;DROP,19"):
            with self.assertRaises(s.Bad):
                s.point(bad, "x")
        self.assertTrue(s.ID.fullmatch("plk-trains:2026-1_2"))
        self.assertFalse(s.ID.fullmatch('x" }) { evil'))

    def test_plan_rejects_bad_mode_before_calling_upstream(self):
        with self.assertRaises(s.Bad):
            s.api_plan({"from": ["50,19"], "to": ["50.1,19.1"], "mode": ["rocket"]})


class Watching(unittest.TestCase):
    def setUp(self):
        s.init_db()
        with s.conn() as c:
            c.executescript("DELETE FROM watches; DELETE FROM events;")

    def test_delay_events_only_on_change(self):
        legs = [{"trip_id": "a:1", "line": "IC 5", "from": "Krakow", "to": "Czestochowa", "scheduled_start": "2026-10-21T14:00:00+02:00"}]
        wid = s.api_watch_add("phone", {"legs": legs})["id"]
        feed = {"delay": 0}
        s.api_trip = lambda q: {"stops": [{"stop": "Krakow", "realtime": True, "delay_s": feed["delay"]}]}
        s.watch_once()  # first live reading
        s.watch_once()  # unchanged
        feed["delay"] = 600
        s.watch_once()
        feed["delay"] = 660  # under the 2 minute threshold
        s.watch_once()
        ev = s.api_events("phone", {})
        self.assertEqual([e["text"] for e in ev], ["IC 5 at Krakow: on time", "IC 5 at Krakow: 10 min late"])
        self.assertEqual(s.api_events("phone", {"since": [str(ev[0]["id"])]})[0]["text"], "IC 5 at Krakow: 10 min late")
        self.assertEqual(s.api_events("other-device", {}), [])
        self.assertTrue(wid)

    def test_limits(self):
        legs = [{"trip_id": "a:1", "line": "1", "from": "A", "to": "B", "scheduled_start": "2026-10-21T14:00:00+02:00"}]
        for _ in range(5):
            s.api_watch_add("d", {"legs": legs})
        with self.assertRaises(s.Bad):
            s.api_watch_add("d", {"legs": legs})
        with self.assertRaises(s.Bad):
            s.api_watch_add("e", {"legs": [{"trip_id": "bad id"}]})


class Shapes(unittest.TestCase):
    def test_polyline_decode_reference(self):
        pts = s.decode_poly("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        self.assertEqual([(round(x, 3), round(y, 3)) for x, y in pts], [(-120.2, 38.5), (-120.95, 40.7), (-126.453, 43.252)])

    def test_signals_and_stops_land_on_the_right_distance(self):
        # a straight east-west street at lat 50, 1 km long; a light 500 m along, one 300 m to the side, one on it twice
        lon0, lat = 19.0, 50.0
        k = 111320.0 * __import__("math").cos(__import__("math").radians(lat))
        lon1 = lon0 + 1000 / k
        def poly(points):
            out, plat, plon = "", 0, 0
            for lo, la in points:
                for cur, prev in ((round(la * 1e5), plat), (round(lo * 1e5), plon)):
                    d = cur - prev
                    v = ~(d << 1) if d < 0 else d << 1
                    while v >= 32:
                        out += chr((32 | (v & 31)) + 63)
                        v >>= 5
                    out += chr(v + 63)
                plat, plon = round(la * 1e5), round(lo * 1e5)
            return out
        sigfile = os.path.join(tempfile.mkdtemp(), "signals.json")
        json.dump([[lon0 + 500 / k, lat + 0.00005], [lon0 + 500 / k, lat + 0.003], [lon0 + 700 / k, lat], [lon0 + 703 / k, lat]], open(sigfile, "w"))
        s.SIG_FILE = sigfile
        s._sig.update(mtime=0, checked=0)
        s.gql = lambda q, v=None: {"trip": {"tripGeometry": {"points": poly([(lon0, lat), (lon1, lat)])},
                                            "stops": [{"name": "mid", "lat": lat, "lon": lon0 + 250 / k}, {"name": "far", "lat": lat + 0.01, "lon": lon0}]}}
        info = s.shape_info("t")
        self.assertAlmostEqual(info["length"], 1000, delta=3)
        self.assertEqual([x["n"] for x in info["stops"]], ["mid"])
        self.assertAlmostEqual(info["stops"][0]["a"], 250, delta=3)
        self.assertEqual(len(info["sig"]), 2)  # side street light ignored, the two near 700 m merge
        self.assertAlmostEqual(info["sig"][0], 500, delta=4)

    def test_vehicle_bbox_validation(self):
        with self.assertRaises(s.Bad):
            s.api_vehicles({"bbox": ["1,2,3"]})
        s._veh.update(t=time.time(), list=[{"id": "a", "lon": 19.0, "lat": 50.0}, {"id": "b", "lon": 30.0, "lat": 50.0}])
        self.assertEqual(s.api_vehicles({"bbox": ["10,40,20,50"]})["vehicles"], [])  # too wide for detail
        self.assertEqual(s.api_vehicles({"bbox": ["10,40,20,50"], "lod": ["heat"]})["heat"], [[19.0, 50.0]])


class Scheduled(unittest.TestCase):
    def test_sched_skips_live_trips_and_lines_stop_times_up_with_the_shape(self):
        at = int(time.time())
        sd = at - at % 86400
        def fake(q, v=None):
            if "stopsByBbox" in q:
                return {"stopsByBbox": [{"gtfsId": "x:1", "lat": 50.0, "lon": 19.0}]}
            if "s0:" in q:
                return {"s0": {"stoptimesWithoutPatterns": [{"serviceDay": sd, "trip": {"gtfsId": "x:live"}}, {"serviceDay": sd, "trip": {"gtfsId": "x:quiet"}}]}}
            self.assertNotIn("x:live", q)
            return {"t0": {"tripHeadsign": "Dom", "route": {"shortName": "7", "mode": "BUS", "agency": {"name": "A"}},
                           "stoptimesForDate": [{"scheduledArrival": 0, "scheduledDeparture": 0, "realtimeArrival": at - sd - 60, "realtimeDeparture": at - sd - 50},
                                                {"scheduledArrival": 0, "scheduledDeparture": 0, "realtimeArrival": at - sd + 300, "realtimeDeparture": at - sd + 310}]}}
        s.gql = fake
        s._veh.update(t=time.time(), list=[{"id": "v", "trip": "x:live", "lon": 19.0, "lat": 50.0}])
        s._sched.clear()
        s._shapes["x:quiet"] = (time.time(), {"points": "", "length": 900, "stops": [], "sig": [], "all": [0, 900]})
        r = s.api_sched({"bbox": ["18.99,49.99,19.01,50.01"]})
        self.assertEqual([t["trip"] for t in r["trips"]], ["x:quiet"])
        self.assertEqual([x[0] for x in r["trips"][0]["st"]], [0, 900])
        self.assertEqual(r["trips"][0]["sd"], sd)
        s._sched.clear()
        s._veh.update(t=time.time(), list=[{"id": "v", "trip": "x:live", "ag": "Z", "lon": 19.0, "lat": 50.0}, {"id": "w", "trip": "x:other", "ag": "A", "lon": 19.0, "lat": 50.0}])
        self.assertEqual(s.api_sched({"bbox": ["18.99,49.99,19.01,50.01"], "gap": ["1"]})["trips"], [], "operator A has live vehicles, so its trips are not estimated")
        s._sched.clear()
        s._veh.update(t=time.time(), list=[{"id": "v", "trip": "x:live", "ag": "Z", "lon": 19.0, "lat": 50.0}, {"id": "w", "trip": "x:other", "ag": "B", "lon": 19.0, "lat": 50.0}])
        self.assertEqual(len(s.api_sched({"bbox": ["18.99,49.99,19.01,50.01"], "gap": ["1"]})["trips"]), 1)
        s._sched.clear()
        with self.assertRaises(s.Bad):
            s.api_sched({"bbox": ["1,2,3"]})
        self.assertEqual(s.api_sched({"bbox": ["10,40,20,50"]})["trips"], [])


class Roofs(unittest.TestCase):
    RING = [{"lat": 50.0, "lon": 19.0}, {"lat": 50.0, "lon": 19.001}, {"lat": 50.001, "lon": 19.001}, {"lat": 50.001, "lon": 19.0}, {"lat": 50.0, "lon": 19.0}]

    def test_overpass_elements_are_trimmed_and_flat_roofs_dropped(self):
        els = [{"type": "way", "id": 1, "tags": {"building": "yes", "roof:shape": "gabled", "height": "12.5 m", "roof:colour": "red", "building:levels": "4"}, "geometry": self.RING},
               {"type": "way", "id": 2, "tags": {"building": "yes", "roof:shape": "flat"}, "geometry": self.RING},
               {"type": "way", "id": 3, "tags": {"building": "yes", "roof:shape": "hipped"}, "geometry": self.RING[:2]},
               {"type": "way", "id": 4, "tags": {"roof:shape": "hipped"}, "geometry": self.RING}]
        out = s.roof_ways(els)
        self.assertEqual([w["id"] for w in out], [1])
        self.assertEqual((out[0]["h"], out[0]["lv"], out[0]["col"]), (12.5, 4.0, "red"))
        self.assertEqual(out[0]["pts"][0], [19.0, 50.0])

    def test_build_file_wins_and_cells_report_readiness(self):
        f = os.path.join(tempfile.mkdtemp(), "roofs.json")
        json.dump([{"id": 9, "shape": "gabled", "h": "10", "lv": None, "rh": None, "rlv": None, "col": None, "mat": None, "dir": None, "pts": [[19.002, 50.002], [19.003, 50.002], [19.003, 50.003], [19.002, 50.003], [19.002, 50.002]]}], open(f, "w"))
        s.ROOF_FILE = f
        s._roof_file.update(mtime=None, grid={})
        r = s.api_roofs({"cells": ["1900,5000;1901,5000"]})
        self.assertEqual([w["id"] for w in r["ways"]], [9])
        self.assertEqual(r["ways"][0]["h"], 10.0)
        self.assertEqual(r["ready"], ["1900,5000", "1901,5000"])
        with self.assertRaises(s.Bad):
            s.api_roofs({"cells": ["a,b"]})
        with self.assertRaises(s.Bad):
            s.api_roofs({"cells": ["99999,1"]})

    def test_without_a_file_a_cell_is_fetched_in_the_background(self):
        s.ROOF_FILE = "/nonexistent/roofs.json"
        s._roofs.clear(); s._roof_busy.clear()
        started = []
        orig = s.threading.Thread
        s.threading.Thread = lambda target, args, daemon: type("T", (), {"start": lambda self: started.append(args)})()
        try:
            r = s.api_roofs({"cells": ["1,2"]})
        finally:
            s.threading.Thread = orig
        self.assertEqual((r["ways"], r["ready"], started), ([], [], [(1, 2)]))
        s._roofs[(1, 2)] = (time.time() + 60, [{"id": 5, "pts": []}], True)
        self.assertEqual(s.api_roofs({"cells": ["1,2"]})["ready"], ["1,2"])


class Elevation(unittest.TestCase):
    def test_tiles_are_validated_cached_and_bounded(self):
        calls = []
        class R:
            def __init__(self, b): self.b = b
            def read(self, n): return self.b
            def __enter__(self): return self
            def __exit__(self, *a): return False
        orig = s.urllib.request.urlopen
        s.urllib.request.urlopen = lambda req, timeout=0: (calls.append(req.full_url), R(b"\x89PNG\r\n" + b"x" * 20))[1]
        try:
            s._dem.clear()
            self.assertTrue(s.dem_tile(14, 8800, 5600).startswith(b"\x89PNG"))
            s.dem_tile(14, 8800, 5600)
            self.assertEqual(len(calls), 1, "the second request is served from memory")
            self.assertIn("/terrarium/14/8800/5600.png", calls[0])
            for bad in ((16, 0, 0), (3, 8, 0), (3, 0, -1)):
                with self.assertRaises(s.Bad):
                    s.dem_tile(*bad)
            s.DEM_KEEP = 3
            for i in range(6):
                s.dem_tile(10, i, 0)
            self.assertLessEqual(len(s._dem), 3)
            s.urllib.request.urlopen = lambda req, timeout=0: R(b"<html>")
            with self.assertRaises(s.Bad):
                s.dem_tile(10, 99, 9)
        finally:
            s.urllib.request.urlopen = orig
            s.DEM_KEEP = 400


class Serving(unittest.TestCase):
    def test_page_carries_build_id_on_every_asset(self):
        html = s.H.__new__(s.H).page().decode()
        import re
        ids = set(re.findall(r"\?v=([0-9a-f]{10})", html))
        self.assertEqual(len(ids), 1)
        for n in ("app.css", "app.js", "vehicles.js", "guide.js", "explore.js", "scene3d.js", "daylight.js", "diorama.js", "fleet.js", "traffic.js", "world.js", "dem.js", "sched.js", "roofs.js"):
            self.assertIn(f"/{n}?v=", html)
        self.assertIn(f'content="{ids.pop()}"', html)

    def test_vehicle_by_trip(self):
        s._veh.update(t=time.time(), list=[{"id": "a", "trip": "t:1", "lon": 1, "lat": 1}, {"id": "b", "trip": "t:2", "lon": 1, "lat": 1}])
        self.assertEqual([v["id"] for v in s.api_vehicles({"trip": ["t:1"]})["vehicles"]], ["a"])
        with self.assertRaises(s.Bad):
            s.api_vehicles({"trip": ["bad id"]})

    def test_api_explore_defaults_and_validation(self):
        orig = s.places.explore
        calls = []
        s.places.explore = lambda cat, lat, lon, r: (calls.append((cat, lat, lon, r)), {"category": cat, "places": []})[1]
        try:
            s.api_explore({"lat": ["50.0614"], "lon": ["19.9371"]})
            self.assertEqual(calls[-1], ("all", 50.0614, 19.9371, 800))
            s.api_explore({"cat": ["cafe"], "lat": ["50.0614"], "lon": ["19.9371"], "r": ["500"]})
            self.assertEqual(calls[-1], ("cafe", 50.0614, 19.9371, 500))
            with self.assertRaises(s.Bad):
                s.api_explore({"lat": ["not_a_num"], "lon": ["19.9371"]})
            s.places.explore = lambda cat, lat, lon, r: (_ for _ in ()).throw(ValueError("unknown category"))
            with self.assertRaises(s.Bad):
                s.api_explore({"cat": ["bogus"], "lat": ["50.0614"], "lon": ["19.9371"]})
        finally:
            s.places.explore = orig



if __name__ == "__main__":
    unittest.main()
