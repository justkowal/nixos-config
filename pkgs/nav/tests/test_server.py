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


if __name__ == "__main__":
    unittest.main()
