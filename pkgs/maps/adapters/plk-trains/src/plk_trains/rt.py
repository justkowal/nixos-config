"""PLK /operations and /disruptions to GTFS-RT, matched against the static index by trip_id + start_date."""
from datetime import datetime

from google.transit import gtfs_realtime_pb2 as pb

from .gtfs import trip_id


def _delay_s(rec, which):
    """seconds late: the API's rounded minutes when present, else actual minus planned (real records often carry only the times)."""
    mins = rec.get(which + "DelayMinutes")
    if mins is not None:
        return mins * 60
    plan, act = rec.get("planned" + which.capitalize()), rec.get("actual" + which.capitalize())
    if plan and act:
        try:
            return int((datetime.fromisoformat(act) - datetime.fromisoformat(plan)).total_seconds())
        except ValueError:
            return None
    return None


def _header(feed, ts):
    feed.header.gtfs_realtime_version = "2.0"
    feed.header.incrementality = pb.FeedHeader.FULL_DATASET
    feed.header.timestamp = int(ts)


def _match(index, sid, oid, toid, day):
    tid = trip_id(sid, oid, toid)
    entry = index["trips"].get(tid)
    d = day.replace("-", "")
    if entry is None or d not in entry["dates"]:
        return None, None
    return tid, entry


def build_trip_updates(trains, index, snapshot_ts):
    """trains: TrainOperationDto dicts from /operations?withPlanned=true. Returns (bytes, stats)."""
    feed = pb.FeedMessage()
    _header(feed, snapshot_ts)
    st = {"seen": len(trains), "unmatched": 0, "matched": 0, "cancelled": 0, "skipped_stops": 0,
          "stop_updates": 0, "ambiguous_stop_updates": 0}
    seen = set()
    for t in trains:
        tid, entry = _match(index, t["scheduleId"], t["orderId"], t.get("trainOrderId"), t["operatingDate"])
        if tid is None:
            st["unmatched"] += 1
            continue
        status = t["trainStatus"]
        day = t["operatingDate"].replace("-", "")
        if status == "C" or (tid, day) in seen:
            continue
        seen.add((tid, day))
        st["matched"] += 1

        ent = feed.entity.add()
        ent.id = "%s_%s" % (tid, day)
        tu = ent.trip_update
        tu.trip.trip_id = tid
        tu.trip.start_date = day
        tu.timestamp = int(snapshot_ts)
        if status == "X":
            tu.trip.schedule_relationship = pb.TripDescriptor.CANCELED
            st["cancelled"] += 1
            continue
        tu.trip.schedule_relationship = pb.TripDescriptor.SCHEDULED

        order = {s: i for i, s in enumerate(entry["stops"])}
        dup = {s for s in entry["stops"] if entry["stops"].count(s) > 1}
        ups = []
        for s in t["stations"] or []:
            sid = str(s["stationId"])
            if sid not in order:
                continue
            if sid in dup:
                st["ambiguous_stop_updates"] += 1
                continue
            ups.append((order[sid], s))
        for _, s in sorted(ups, key=lambda x: x[0]):
            stu = tu.stop_time_update.add()
            stu.stop_id = str(s["stationId"])
            if s.get("isCancelled"):
                stu.schedule_relationship = pb.TripUpdate.StopTimeUpdate.SKIPPED
                st["skipped_stops"] += 1
                continue
            ad, dd = _delay_s(s, "arrival"), _delay_s(s, "departure")
            if ad is None and dd is None:
                tu.stop_time_update.pop()
                continue
            if ad is not None:
                stu.arrival.delay = ad
            if dd is not None:
                stu.departure.delay = dd
            stu.schedule_relationship = pb.TripUpdate.StopTimeUpdate.SCHEDULED
            st["stop_updates"] += 1
        if not tu.stop_time_update:
            feed.entity.pop()
            st["matched"] -= 1
    return feed.SerializeToString(), st


def build_alerts(resp, index, now):
    feed = pb.FeedMessage()
    _header(feed, now)
    types = resp.get("disruptionTypes") or {}
    st = {"disruptions": len(resp["disruptions"] or []), "published": 0, "unmatched": 0}
    for d in resp["disruptions"] or []:
        targets = set()
        for a in d.get("affectedRoutes") or []:
            tid, _ = _match(index, a["scheduleId"], a["orderId"], a.get("trainOrderId"), a["operatingDate"])
            if tid:
                targets.add((tid, a["operatingDate"].replace("-", "")))
        if not targets:
            st["unmatched"] += 1
            continue
        e = feed.entity.add()
        e.id = "disruption-%d" % d["disruptionId"]
        al = e.alert
        al.cause = pb.Alert.UNKNOWN_CAUSE
        al.effect = pb.Alert.UNKNOWN_EFFECT
        for tid, day in sorted(targets):
            ie = al.informed_entity.add()
            ie.trip.trip_id = tid
            ie.trip.start_date = day
        msg = d.get("message") or ""
        head = types.get(d.get("disruptionTypeCode") or "") or msg[:100]
        for field, text in ((al.header_text, head), (al.description_text, msg)):
            if text:
                tr = field.translation.add()
                tr.text, tr.language = text, "pl"
        st["published"] += 1
    return feed.SerializeToString(), st
