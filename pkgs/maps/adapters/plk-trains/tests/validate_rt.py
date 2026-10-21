"""Structural GTFS-RT check against the static zip it ships with (stand-in for the MobilityData
validator, which has no offline CLI release).

usage: python tests/validate_rt.py GTFS_ZIP FEED.pb [FEED.pb ...]
Exit code 1 on any error. Prints one line per finding.
"""
import csv
import io
import sys
import zipfile

from google.transit import gtfs_realtime_pb2 as pb


def load_static(path):
    z = zipfile.ZipFile(path)
    rd = lambda n: list(csv.DictReader(io.StringIO(z.read(n).decode("utf8"))))  # noqa: E731
    stops = {}
    for r in sorted(rd("stop_times.txt"), key=lambda r: (r["trip_id"], int(r["stop_sequence"]))):
        stops.setdefault(r["trip_id"], []).append(r["stop_id"])
    trips = {r["trip_id"]: r["service_id"] for r in rd("trips.txt")}
    dates = {}
    for r in rd("calendar_dates.txt"):
        if r["exception_type"] == "1":
            dates.setdefault(r["service_id"], set()).add(r["date"])
    return stops, trips, dates


def check(path, stops, trips, dates):
    errs, warns = [], []
    feed = pb.FeedMessage()
    feed.ParseFromString(open(path, "rb").read())
    h = feed.header
    if h.gtfs_realtime_version != "2.0":
        errs.append("E001 header.gtfs_realtime_version is not 2.0")
    if h.incrementality != pb.FeedHeader.FULL_DATASET:
        errs.append("E002 incrementality is not FULL_DATASET")
    if not h.timestamp:
        errs.append("E003 header.timestamp missing")
    ids = [e.id for e in feed.entity]
    if len(ids) != len(set(ids)):
        errs.append("E004 duplicate entity ids")
    for e in feed.entity:
        if e.HasField("trip_update"):
            tu = e.trip_update
            tid, sd = tu.trip.trip_id, tu.trip.start_date
            if tid not in trips:
                errs.append("E010 %s: trip_id not in static feed" % e.id)
                continue
            if sd not in dates.get(trips[tid], set()):
                errs.append("E011 %s: start_date %s not in service calendar" % (e.id, sd))
            if tu.timestamp and tu.timestamp > h.timestamp:
                errs.append("E012 %s: trip_update.timestamp after header.timestamp" % e.id)
            if tu.trip.schedule_relationship == pb.TripDescriptor.CANCELED and tu.stop_time_update:
                errs.append("E013 %s: CANCELED trip carries stop_time_updates" % e.id)
            if tu.trip.schedule_relationship != pb.TripDescriptor.CANCELED and not tu.stop_time_update:
                errs.append("E014 %s: no stop_time_update" % e.id)
            order = stops[tid]
            last = -1
            for u in tu.stop_time_update:
                if u.stop_id not in order:
                    errs.append("E015 %s: stop %s not on static trip" % (e.id, u.stop_id))
                    continue
                pos = order.index(u.stop_id)
                if pos <= last:
                    errs.append("E016 %s: stop_time_updates out of order" % e.id)
                last = pos
                if u.schedule_relationship == pb.TripUpdate.StopTimeUpdate.SCHEDULED \
                        and not (u.HasField("arrival") or u.HasField("departure")):
                    errs.append("E017 %s: scheduled update without arrival or departure" % e.id)
        elif e.HasField("alert"):
            a = e.alert
            if not a.informed_entity:
                errs.append("E020 %s: alert without informed_entity" % e.id)
            if not a.header_text.translation:
                errs.append("E021 %s: alert without header_text" % e.id)
            for ie in a.informed_entity:
                if ie.trip.trip_id not in trips:
                    errs.append("E022 %s: informed trip not in static feed" % e.id)
        else:
            errs.append("E030 %s: entity is neither trip_update nor alert" % e.id)
    if not feed.entity:
        warns.append("W001 feed has no entities")
    return errs, warns, len(feed.entity)


if __name__ == "__main__":
    stops, trips, dates = load_static(sys.argv[1])
    bad = 0
    for p in sys.argv[2:]:
        errs, warns, n = check(p, stops, trips, dates)
        print("%s: %d entities, %d errors, %d warnings" % (p, n, len(errs), len(warns)))
        for line in errs + warns:
            print("  " + line)
        bad += len(errs)
    sys.exit(1 if bad else 0)

