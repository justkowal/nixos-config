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
        cur_delay = None
        for _, s in sorted(ups, key=lambda x: x[0]):
            stu = tu.stop_time_update.add()
            stu.stop_id = str(s["stationId"])
            if s.get("isCancelled"):
                stu.schedule_relationship = pb.TripUpdate.StopTimeUpdate.SKIPPED
                st["skipped_stops"] += 1
                continue
            ad, dd = _delay_s(s, "arrival"), _delay_s(s, "departure")
            if ad is None and dd is not None:
                cur_delay = dd
            elif dd is None and ad is not None:
                cur_delay = ad
            elif ad is not None and dd is not None:
                cur_delay = dd
            elif ad is None and dd is None:
                tu.stop_time_update.pop()
                continue
            if ad is not None:
                stu.arrival.delay = ad
            if dd is not None:
                stu.departure.delay = dd
            stu.schedule_relationship = pb.TripUpdate.StopTimeUpdate.SCHEDULED
            st["stop_updates"] += 1
        if cur_delay is not None:
            tu.delay = cur_delay
        if not tu.stop_time_update:
            feed.entity.pop()
            st["matched"] -= 1
    return feed.SerializeToString(), st


def build_vehicle_positions(trains, index, snapshot_ts):
    """Synthesizes vehicle positions for active trains based on timetable + current delay."""
    feed = pb.FeedMessage()
    _header(feed, snapshot_ts)
    positions = index.get("positions", {})
    st = {"published": 0}
    seen = set()

    from zoneinfo import ZoneInfo
    waw = ZoneInfo("Europe/Warsaw")

    for t in trains:
        tid, entry = _match(index, t["scheduleId"], t["orderId"], t.get("trainOrderId"), t["operatingDate"])
        if tid is None:
            continue
        status = t["trainStatus"]
        day = t["operatingDate"].replace("-", "")
        if status in ("C", "X") or (tid, day) in seen:
            continue
        seen.add((tid, day))

        # Determine latest observed delay for the train
        latest_delay = 0
        for s in t.get("stations") or []:
            ad, dd = _delay_s(s, "arrival"), _delay_s(s, "departure")
            if dd is not None:
                latest_delay = dd
            elif ad is not None:
                latest_delay = ad

        times = entry.get("times")
        if not times or len(times) < 2:
            continue

        try:
            dt = datetime.strptime(day, "%Y%m%d")
            mid = int(datetime(dt.year, dt.month, dt.day, tzinfo=waw).timestamp())
        except Exception:
            continue

        first_dep = mid + times[0][1] + latest_delay
        last_arr = mid + times[-1][0] + latest_delay
        now = int(snapshot_ts)

        if not (first_dep - 300 <= now <= last_arr + 300):
            continue

        pos_res = None
        for idx_stop in range(len(times)):
            arr, dep, sid = times[idx_stop]
            s_arr = mid + arr + latest_delay
            s_dep = mid + dep + latest_delay
            latlon = positions.get(sid)
            if not latlon:
                continue

            if s_arr <= now <= s_dep or (idx_stop == 0 and now < s_dep) or (idx_stop == len(times) - 1 and now >= s_arr):
                pos_res = (latlon[0], latlon[1], pb.VehiclePosition.STOPPED_AT, sid)
                break

            if idx_stop + 1 < len(times):
                next_arr, _, next_sid = times[idx_stop + 1]
                s_next_arr = mid + next_arr + latest_delay
                if s_dep < now < s_next_arr:
                    next_latlon = positions.get(next_sid)
                    if next_latlon:
                        duration = s_next_arr - s_dep
                        frac = max(0.0, min(1.0, (now - s_dep) / duration)) if duration > 0 else 0.5
                        lat = latlon[0] + frac * (next_latlon[0] - latlon[0])
                        lon = latlon[1] + frac * (next_latlon[1] - latlon[1])
                        pos_res = (lat, lon, pb.VehiclePosition.IN_TRANSIT_TO, next_sid)
                        break

        if pos_res is None:
            continue

        lat, lon, vstatus, sid = pos_res
        ent = feed.entity.add()
        ent.id = f"vp_{tid}_{day}"
        vp = ent.vehicle
        vp.trip.trip_id = tid
        vp.trip.start_date = day
        vp.position.latitude = lat
        vp.position.longitude = lon
        vp.current_status = vstatus
        vp.stop_id = str(sid)
        vp.timestamp = int(snapshot_ts)
        vp.vehicle.id = f"plk-{tid}"
        vp.vehicle.label = entry.get("short_name") or "PKP"
        st["published"] += 1

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
