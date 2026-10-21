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


class Serving(unittest.TestCase):
    def test_page_carries_build_id_on_every_asset(self):
        html = s.H.__new__(s.H).page().decode()
        import re
        ids = set(re.findall(r"\?v=([0-9a-f]{10})", html))
        self.assertEqual(len(ids), 1)
        for n in ("app.css", "app.js", "vehicles.js", "guide.js", "explore.js", "scene3d.js", "daylight.js", "diorama.js"):
            self.assertIn(f"/{n}?v=", html)
        self.assertIn(f'content="{ids.pop()}"', html)

    def test_vehicle_by_trip(self):
        s._veh.update(t=time.time(), list=[{"id": "a", "trip": "t:1", "lon": 1, "lat": 1}, {"id": "b", "trip": "t:2", "lon": 1, "lat": 1}])
        self.assertEqual([v["id"] for v in s.api_vehicles({"trip": ["t:1"]})["vehicles"]], ["a"])
        with self.assertRaises(s.Bad):
            s.api_vehicles({"trip": ["bad id"]})


if __name__ == "__main__":
    unittest.main()
