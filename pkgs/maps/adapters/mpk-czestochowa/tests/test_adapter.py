import datetime as dt
import json
import os
import shutil
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "adapter"))
FIX = os.path.join(HERE, "fixtures")

import guard as G  # noqa: E402
import static as S  # noqa: E402
import rt as R  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s


def mkguard(tmp, clock, **kw):
    args = dict(spacing_s=5, jitter_s=0, hourly_budget=100, cooldown_s=21600, error_run=3)
    args.update(kw)
    return G.Guard("t", tmp, clock=clock.now, sleep=clock.sleep, **args)


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.c = Clock()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_spacing(self):
        g = mkguard(self.tmp, self.c)
        g.acquire()
        t0 = self.c.t
        g.acquire()
        self.assertGreaterEqual(self.c.t - t0, 5)

    def test_budget(self):
        g = mkguard(self.tmp, self.c, hourly_budget=3)
        for _ in range(3):
            g.acquire()
        with self.assertRaises(G.Blocked):
            g.acquire()
        self.c.t += 3601
        g.acquire()

    def test_ban_statuses_open_breaker_for_cooldown(self):
        for st in (403, 429):
            g = mkguard(self.tmp, self.c)
            g.acquire()
            g.record(status=st)
            self.assertTrue(g.breaker_open())
            with self.assertRaises(G.Blocked):
                g.acquire()
            self.c.t += 21601
            g.acquire()
            g.errors = 0
            g.breaker_until = 0

    def test_redirect_and_challenge_trip(self):
        g = mkguard(self.tmp, self.c)
        g.record(status=302, redirected=True)
        self.assertTrue(g.breaker_open())
        g2 = mkguard(self.tmp, self.c)
        g2.breaker_until = 0
        g2.record(status=200, blocked_body=True)
        self.assertTrue(g2.breaker_open())

    def test_error_run_and_backoff(self):
        g = mkguard(self.tmp, self.c)
        g.acquire()
        g.record(error=True)
        t0 = self.c.t
        g.acquire()
        self.assertGreaterEqual(self.c.t - t0, 5 + 10)
        g.record(error=True)
        g.record(error=True)
        self.assertTrue(g.breaker_open())

    def test_state_survives_restart(self):
        g = mkguard(self.tmp, self.c)
        g.acquire()
        g.record(status=429)
        g2 = mkguard(self.tmp, self.c)
        self.assertTrue(g2.breaker_open())
        self.assertEqual(g2.used_last_hour(), 1)

    def test_kill_file(self):
        kf = os.path.join(self.tmp, "KILL")
        g = mkguard(self.tmp, self.c, kill_file=kf)
        open(kf, "w").close()
        with self.assertRaises(G.Blocked):
            g.acquire()


class StaticTest(unittest.TestCase):
    def test_pick_folder_ignores_future_and_files(self):
        entries = S.parse_listing(open(os.path.join(FIX, "propfind_root_dir.xml"), "rb").read())
        self.assertEqual(S.pick_folder(entries, dt.date(2026, 10, 21)), "2026.10.19")
        self.assertEqual(S.pick_folder(entries, dt.date(2026, 11, 5)), "2026.11.02")

    def test_latest_dir_listing_has_gtfs_zip_with_etag(self):
        entries = S.parse_listing(open(os.path.join(FIX, "propfind_latest_dir.xml"), "rb").read())
        e = next(x for x in entries if x["name"] == "GTFS_2026.10.19.zip")
        self.assertTrue(e["etag"])

    def make_zip(self, tmp):
        p = os.path.join(tmp, "src.zip")
        d = os.path.join(FIX, "gtfs_mini")
        with zipfile.ZipFile(p, "w") as z:
            for n in os.listdir(d):
                z.write(os.path.join(d, n), n)
            z.writestr("[Content_Types].xml", "x")
            z.writestr("transfers.txt", "from_stop_id,to_stop_id,transfer_type,min_transfer_time\n")
        return p

    def test_patch_zip(self):
        tmp = tempfile.mkdtemp()
        try:
            out = os.path.join(tmp, "out.zip")
            S.patch_zip(open(self.make_zip(tmp), "rb").read(), "2026.10.19", out)
            z = zipfile.ZipFile(out)
            names = z.namelist()
            self.assertIn("attributions.txt", names)
            self.assertIn("LICENSE.txt", names)
            self.assertNotIn("[Content_Types].xml", names)
            self.assertNotIn("transfers.txt", names)
            self.assertIn("feed_version", z.read("feed_info.txt").decode())
            idx = S.GtfsIndex(out)
            self.assertEqual(idx.version, "2026.10.19")
            self.assertIn("97634", idx.trips)
        finally:
            shutil.rmtree(tmp)


class RtTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        p = os.path.join(cls.tmp, "g.zip")
        d = os.path.join(FIX, "gtfs_mini")
        with zipfile.ZipFile(p, "w") as z:
            for n in os.listdir(d):
                z.write(os.path.join(d, n), n)
        cls.index = S.GtfsIndex(p)
        fx = json.load(open(os.path.join(FIX, "vehicles_status.json")))
        cls.vehicles, cls.now = fx["vehicles"], fx["received_at"]
        cls.meta = {v["vehicleID"]: v for v in json.load(open(os.path.join(FIX, "api_vehicles.json")))}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def test_trip_update_attaches_to_static_trip(self):
        tu, vp, stats = R.build(self.vehicles, self.meta, self.index, self.now)
        self.assertEqual(stats["matched"], 3)
        self.assertEqual(len(tu.entity), 3)
        e = next(x for x in tu.entity if x.trip_update.trip.trip_id == "97634")
        t = e.trip_update.trip
        self.assertEqual((t.route_id, t.start_date, t.direction_id), ("1282", "20261020", 0))
        stus = e.trip_update.stop_time_update
        seqs = [s.stop_sequence for s in stus]
        self.assertEqual(seqs, sorted(seqs))
        trip_seqs = {s[0] for s in self.index.times["97634"]}
        self.assertTrue(set(seqs) <= trip_seqs)
        run = next(v for v in self.vehicles if v["currentRun"]["foreignID"] == "97634")["currentRun"]
        li = max(i for i, s in enumerate(run["runStops"]) if s["arrivalTime"])
        seq = self.index.times["97634"][li][0]
        sched = self.index.times["97634"][li][3]
        base = R.epoch(run["runStops"][0]["time"]) - self.index.times["97634"][0][2]
        want = int(R.epoch(run["runStops"][li]["departureTime"]) - (base + sched))
        last = next(s for s in stus if s.stop_sequence == seq)
        self.assertEqual(last.departure.delay, want)
        self.assertEqual(e.trip_update.delay, want)
        nxt = next(s for s in stus if s.stop_sequence == seq + 1)
        self.assertEqual(nxt.arrival.delay, want)

    def test_vehicle_positions(self):
        tu, vp, stats = R.build(self.vehicles, self.meta, self.index, self.now)
        self.assertEqual(len(vp.entity), 3)
        v = next(x.vehicle for x in vp.entity if x.vehicle.trip.trip_id == "97634")
        self.assertAlmostEqual(v.position.latitude, 50.8364, places=3)
        self.assertGreater(v.current_stop_sequence, 1)
        self.assertIn(v.stop_id, {s[1] for s in self.index.times["97634"]})
        self.assertEqual(vp.header.incrementality, 0)

    def test_stale_vehicle_dropped(self):
        tu, vp, stats = R.build(self.vehicles, self.meta, self.index, self.now + 1000)
        self.assertEqual(len(vp.entity), 0)

    def test_unknown_trip_gets_no_trip_descriptor(self):
        import copy
        vs = copy.deepcopy(self.vehicles)
        for v in vs:
            if v.get("lastPosition"):
                v["currentRun"]["foreignID"] = "999999"
        tu, vp, stats = R.build(vs, self.meta, self.index, self.now)
        self.assertEqual(len(tu.entity), 0)
        self.assertEqual(stats["unmatched"], {"unknown trip": 3})
        self.assertFalse(any(e.vehicle.HasField("trip") for e in vp.entity))

    def test_time_mismatch_is_rejected(self):
        import copy
        vs = copy.deepcopy(self.vehicles)
        for v in vs:
            if v.get("lastPosition"):
                for s in v["currentRun"]["runStops"]:
                    s["time"] = (dt.datetime.fromisoformat(s["time"].replace("Z", "+00:00"))
                                 + dt.timedelta(minutes=10)).isoformat()
        tu, vp, stats = R.build(vs, self.meta, self.index, self.now)
        self.assertEqual(stats["matched"], 0)

    def test_in_service_window(self):
        night = dt.datetime(2026, 10, 21, 2, 30, tzinfo=S.TZ).timestamp()
        self.assertTrue(self.index.in_service(night))
        noon = dt.datetime(2026, 10, 21, 12, 0, tzinfo=S.TZ).timestamp()
        self.assertFalse(self.index.in_service(noon))


if __name__ == "__main__":
    unittest.main()
