"""plan() query shape and the arrive-by fallback, with OTP stubbed: python3 -m unittest test_routing_plan"""
import json
import os
import tempfile
import unittest

os.environ.setdefault("FEED_CONTACT", "test")
d = tempfile.mkdtemp()
open(os.path.join(d, "m.json"), "w").write(json.dumps({"feeds": [{"id": "x"}]}))
os.environ["GRAPH_MANIFEST"] = os.path.join(d, "m.json")
os.environ["STATE_DIR"] = d
import routing_mcp as r  # noqa: E402


def leg(mode="BUS"):
    return {"mode": mode, "duration": 600, "distance": 1000, "realTime": False, "headsign": "X", "from": {"name": "A"}, "to": {"name": "B"},
            "start": {"scheduledTime": "2026-10-22T07:02:00+02:00", "estimated": None}, "end": {"scheduledTime": "2026-10-22T09:16:00+02:00"},
            "route": {"shortName": "1", "longName": "1", "agency": {"name": "Z"}}, "steps": []}


def edge(end):
    return {"node": {"start": "2026-10-22T07:02:00+02:00", "end": end, "duration": 7000, "numberOfTransfers": 0, "legs": [leg()]}}


class Plan(unittest.TestCase):
    def setUp(self):
        self.queries = []
        r.resolve = lambda p: {"query": p, "name": p, "lat": 50.0, "lon": 19.0}
        r.budget = lambda: None

    def stub(self, *answers):
        it = iter(answers)

        def gql(q, v=None):
            self.queries.append(q)
            return {"planConnection": {"edges": next(it)}}
        r.gql = gql

    def test_street_route_is_direct_only(self):
        self.stub([edge("2026-10-22T07:20:00+02:00")])
        out = json.loads(r.t_route({"from": "a", "to": "b", "mode": "walk"}))
        self.assertIn("directOnly:true", self.queries[0])
        self.assertEqual(len(out["itineraries"]), 1)

    def test_arrive_by_falls_back_to_closest_options_with_lateness(self):
        self.stub([], [edge("2026-10-22T09:16:00+02:00")])
        out = json.loads(r.t_transit_plan({"from": "a", "to": "b", "arrive_by": "2026-10-22T09:00"}))
        self.assertIn("latestArrival", self.queries[0])
        self.assertIn("earliestDeparture", self.queries[1])
        self.assertEqual(out["itineraries"][0]["misses_deadline_by_min"], 16)
        self.assertIn("closest", out["note"])

    def test_arrive_by_in_time_has_no_lateness_marker(self):
        self.stub([edge("2026-10-22T08:50:00+02:00")])
        out = json.loads(r.t_transit_plan({"from": "a", "to": "b", "arrive_by": "2026-10-22T09:00"}))
        self.assertNotIn("misses_deadline_by_min", out["itineraries"][0])
        self.assertNotIn("note", out)

    def test_nothing_found_explains_why(self):
        self.stub([], [])
        with self.assertRaises(RuntimeError) as c:
            r.t_transit_plan({"from": "a", "to": "b", "arrive_by": "2026-10-22T09:00"})
        self.assertIn("no route found", str(c.exception))
        self.stub([])
        with self.assertRaises(RuntimeError) as c:
            r.t_route({"from": "a", "to": "b", "mode": "car"})
    def test_transit_plan_headroom_filtering(self):
        def transfer_edge(start_train, end_walk):
            legs = [
                {"mode": "BUS", "duration": 600, "distance": 1000, "realTime": False, "headsign": "X",
                 "from": {"name": "A"}, "to": {"name": "Station Bus Stop"},
                 "start": {"scheduledTime": "2026-10-22T08:00:00+02:00", "estimated": None},
                 "end": {"scheduledTime": "2026-10-22T08:20:00+02:00"},
                 "route": {"shortName": "1", "longName": "1", "agency": {"name": "Z"}}, "steps": []},
                {"mode": "WALK", "duration": 300, "distance": 200, "realTime": False, "headsign": None,
                 "from": {"name": "Station Bus Stop"}, "to": {"name": "Platform 1"},
                 "start": {"scheduledTime": "2026-10-22T08:20:00+02:00", "estimated": None},
                 "end": {"scheduledTime": end_walk},
                 "route": None, "steps": []},
                {"mode": "RAIL", "duration": 1800, "distance": 30000, "realTime": False, "headsign": "Dest",
                 "from": {"name": "Platform 1"}, "to": {"name": "B"},
                 "start": {"scheduledTime": start_train, "estimated": None},
                 "end": {"scheduledTime": "2026-10-22T09:10:00+02:00"},
                 "route": {"shortName": "IC", "longName": "IC", "agency": {"name": "PKP"}}, "steps": []}
            ]
            return {"node": {"start": "2026-10-22T08:00:00+02:00", "end": "2026-10-22T09:10:00+02:00",
                             "duration": 4200, "numberOfTransfers": 1, "legs": legs}}

        # Edge 1: walk ends 08:25, train starts 08:30 -> 5m headroom
        # Edge 2: walk ends 08:25, train starts 08:40 -> 15m headroom
        self.stub([transfer_edge("2026-10-22T08:30:00+02:00", "2026-10-22T08:25:00+02:00"),
                   transfer_edge("2026-10-22T08:40:00+02:00", "2026-10-22T08:25:00+02:00")])
        out = json.loads(r.t_transit_plan({"from": "a", "to": "b", "headroom_rail": 10}))
        self.assertEqual(len(out["itineraries"]), 1)
        self.assertEqual(out["itineraries"][0]["legs"][2]["start"], "08:40")
        self.assertIn("hr_rail=10", out["app_link"])


if __name__ == "__main__":
    unittest.main()
