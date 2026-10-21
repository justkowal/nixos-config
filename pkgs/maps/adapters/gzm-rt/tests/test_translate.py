import csv
import io
import os
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
from google.transit import gtfs_realtime_pb2 as pb  # noqa: E402

from gzm_rt import app, translate as tr  # noqa: E402

NOON = datetime(2026, 10, 21, 12, 0, tzinfo=tr.WAW).timestamp()
NIGHT = datetime(2026, 10, 22, 1, 30, tzinfo=tr.WAW).timestamp()


def make_zip():
    p = os.path.join(tempfile.mkdtemp(), "ids.zip")

    def w(z, name, rows):
        o = io.StringIO()
        c = csv.writer(o, lineterminator="\n")
        [c.writerow(r) for r in rows]
        z.writestr(name, o.getvalue())
    with zipfile.ZipFile(p, "w") as z:
        w(z, "calendar_dates.txt", [["service_id", "date", "exception_type"], ["11607:1", "20261021", 1], ["11608:1", "20261022", 1], ["11607:7", "20261021", 1]])
        w(z, "trips.txt", [["route_id", "service_id", "trip_id"], ["r", "11607:1", "11607:1_100"], ["r", "11608:1", "11608:1_100"], ["r", "11607:1", "11607:1_200"]])
    return p


class T(unittest.TestCase):
    def setUp(self):
        self.s, self.t = tr.load_ids(make_zip())

    def test_today(self):
        self.assertEqual(tr.translate("1_100", self.s, self.t, NOON), ("11607:1_100", "20261021"))

    def test_night_trip_belongs_to_yesterday(self):
        self.assertEqual(tr.translate("1_200", self.s, self.t, NIGHT), ("11607:1_200", "20261021"))

    def test_after_midnight_prefers_the_day_that_has_the_trip(self):
        self.assertEqual(tr.translate("1_100", self.s, self.t, NIGHT), ("11608:1_100", "20261022"))

    def test_unknown_trip_is_none(self):
        self.assertIsNone(tr.translate("1_999", self.s, self.t, NOON))
        self.assertIsNone(tr.translate("9_100", self.s, self.t, NOON))

    def test_rewrite_keeps_payload_and_drops_unplaced(self):
        f = pb.FeedMessage()
        f.header.gtfs_realtime_version = "2.0"
        for i in ("1_100", "1_999"):
            e = f.entity.add()
            e.id = i
            e.trip_update.trip.trip_id = i
            u = e.trip_update.stop_time_update.add()
            u.stop_sequence, u.arrival.delay = 4, 120
        data, kept, dropped = app.rewrite(f.SerializeToString(), self.s, self.t, NOON, "tu")
        out = pb.FeedMessage()
        out.ParseFromString(data)
        self.assertEqual((kept, dropped, len(out.entity)), (1, 1, 1))
        tu = out.entity[0].trip_update
        self.assertEqual((tu.trip.trip_id, tu.trip.start_date, tu.stop_time_update[0].arrival.delay, tu.stop_time_update[0].stop_sequence), ("11607:1_100", "20261021", 120, 4))

    def test_vehicle_positions(self):
        f = pb.FeedMessage()
        f.header.gtfs_realtime_version = "2.0"
        e = f.entity.add()
        e.id = "v"
        e.vehicle.trip.trip_id = "1_100"
        e.vehicle.position.latitude = 50.3
        e.vehicle.position.longitude = 19.0
        data, kept, _ = app.rewrite(f.SerializeToString(), self.s, self.t, NOON, "vp")
        out = pb.FeedMessage()
        out.ParseFromString(data)
        self.assertEqual((kept, out.entity[0].vehicle.trip.trip_id, round(out.entity[0].vehicle.position.latitude, 1)), (1, "11607:1_100", 50.3))


if __name__ == "__main__":
    unittest.main()
