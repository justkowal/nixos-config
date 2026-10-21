"""Structural GTFS-RT check on a feed built from recorded fixtures and the FULL official static feed.

Usage: validate_rt.py <static.zip> > reports/gtfs-rt-structural-check.txt
The MobilityData GTFS-RT validator has no release artifact and needs a Maven build,
so this covers the rules that matter for matching instead.
"""
import json
import os
import sys

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "adapter"))
from google.transit import gtfs_realtime_pb2 as pb  # noqa: E402

import rt  # noqa: E402
import static  # noqa: E402

idx = static.GtfsIndex(sys.argv[1])
fx = json.load(open(os.path.join(HERE, "fixtures", "vehicles_status.json")))
meta = {v["vehicleID"]: v for v in json.load(open(os.path.join(HERE, "fixtures", "api_vehicles.json")))}
tu, vp, stats = rt.build(fx["vehicles"], meta, idx, fx["received_at"])
problems = []
for name, feed in (("trip_updates", tu), ("vehicle_positions", vp)):
    raw = feed.SerializeToString()
    back = pb.FeedMessage()
    back.ParseFromString(raw)
    h = back.header
    ids = [e.id for e in back.entity]
    checks = {
        "version 2.0": h.gtfs_realtime_version == "2.0",
        "FULL_DATASET": h.incrementality == pb.FeedHeader.FULL_DATASET,
        "header timestamp set": h.timestamp > 0,
        "unique entity ids": len(ids) == len(set(ids)),
    }
    for e in back.entity:
        t = e.trip_update.trip if e.HasField("trip_update") else e.vehicle.trip
        if not (e.HasField("trip_update") or e.vehicle.HasField("trip")):
            continue
        trip = idx.trips.get(t.trip_id)
        checks[f"{e.id} trip_id in static"] = trip is not None
        checks[f"{e.id} route_id matches static"] = trip is not None and trip["route_id"] == t.route_id
        checks[f"{e.id} start_date service active"] = trip is not None and idx.service_active(
            trip["service_id"], __import__("datetime").datetime.strptime(t.start_date, "%Y%m%d").date())
        if e.HasField("trip_update"):
            valid = {(s[0], s[1]) for s in idx.times[t.trip_id]}
            seqs = [s.stop_sequence for s in e.trip_update.stop_time_update]
            checks[f"{e.id} stop_sequence/stop_id pairs exist in static"] = all(
                (s.stop_sequence, s.stop_id) in valid for s in e.trip_update.stop_time_update)
            checks[f"{e.id} stop_sequence strictly increasing"] = seqs == sorted(set(seqs))
    print(f"[{name}] entities={len(back.entity)} bytes={len(raw)}")
    for k, ok in checks.items():
        print(("  PASS " if ok else "  FAIL ") + k)
        if not ok:
            problems.append((name, k))
print("match stats:", stats)
print("RESULT:", "OK" if not problems else f"{len(problems)} failures")
sys.exit(1 if problems else 0)
