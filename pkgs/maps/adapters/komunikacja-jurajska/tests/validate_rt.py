"""Structural GTFS-RT check on feeds built from recorded fixtures, cross-checked against the static zip.

Usage: validate_rt.py <static.zip> > reports/gtfs-rt-structural-check.txt
The zip must come from build_sample_feed.py (or a full crawl that includes line 151).
The MobilityData GTFS-RT validator has no offline release, so this covers the matching rules instead.
"""
import json
import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_adapter as t  # noqa: E402
from google.transit import gtfs_realtime_pb2 as pb  # noqa: E402

with open(sys.argv[1], "rb") as f:
    idx = t.gtfs.Index(f.read())
kp_stops = {r[0]: {"designator": r[1], "name": r[2]} for r in t.fx("stops.json")["stops"]}
rt = t.Rt({})
rt.set_static(idx, kp_stops)
src = t.FixtureKp()
resp = src.departures([t.BLACH, "622548"])
_, need = rt.ingest_departures(resp, t.NOW_DEP)
for ktid, kidx, dt in sorted(need):
    if os.path.exists(os.path.join(t.FX, "trips", f"{ktid}.json")):
        rt.map_trip(ktid, src.trip(ktid, kidx), dt, t.NOW_DEP)
rt.ingest_departures(resp, t.NOW_DEP)
mapped = rt.map["38155603|wd"]["op"]
rt.ingest_execution("38155603", mapped, "20261021", src.trip_execution("151:739910:4", 17), t.NOW_DEP)
out = rt.build(t.NOW_DEP + 5)
problems = []
for name, raw in (("trip_updates", out[0]), ("vehicle_positions", out[1])):
    feed = pb.FeedMessage()
    feed.ParseFromString(raw)
    h = feed.header
    ids = [e.id for e in feed.entity]
    checks = {"version 2.0": h.gtfs_realtime_version == "2.0",
              "FULL_DATASET": h.incrementality == pb.FeedHeader.FULL_DATASET,
              "header timestamp set": h.timestamp > 0,
              "has entities": len(ids) > 0,
              "unique entity ids": len(ids) == len(set(ids))}
    for e in feed.entity:
        trip = e.trip_update.trip if e.HasField("trip_update") else e.vehicle.trip
        tid = trip.trip_id
        datetime.strptime(trip.start_date, "%Y%m%d")
        checks[f"{e.id} trip_id in static"] = tid in idx.trips
        checks[f"{e.id} route_id matches static"] = idx.trips.get(tid, {}).get("route_id") == trip.route_id
        checks[f"{e.id} start_date set and service active"] = idx.active(tid, trip.start_date)
        if e.HasField("trip_update"):
            ups = e.trip_update.stop_time_update
            seqs = [u.stop_sequence for u in ups]
            checks[f"{e.id} stop_sequence strictly increasing"] = seqs == sorted(set(seqs))
            checks[f"{e.id} every stop_id attaches to its stop_sequence in static"] = all(
                idx.stop_at(tid, u.stop_sequence) == u.stop_id for u in ups)
            checks[f"{e.id} delay present or SKIPPED"] = all(
                u.schedule_relationship == pb.TripUpdate.StopTimeUpdate.SKIPPED or u.HasField("arrival") for u in ups)
        else:
            v = e.vehicle
            checks[f"{e.id} stop_id attaches to current_stop_sequence"] = (
                idx.stop_at(tid, v.current_stop_sequence) == v.stop_id)
            checks[f"{e.id} position inside the service area"] = (
                49 < v.position.latitude < 52 and 18 < v.position.longitude < 20)
    print(f"[{name}] entities={len(feed.entity)} bytes={len(raw)} header_ts={h.timestamp}")
    for k, ok in checks.items():
        print(("  PASS " if ok else "  FAIL ") + k)
        if not ok:
            problems.append((name, k))
print("live trip 38155603 (wd) mapped to operator trip", mapped)
print("match stats:", json.dumps(rt.stats))
print("RESULT:", "OK" if not problems else f"{len(problems)} failures")
sys.exit(1 if problems else 0)
