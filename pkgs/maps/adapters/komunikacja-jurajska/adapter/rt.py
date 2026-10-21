"""GTFS-RT from the site's departure boards and trip_execution calls, matched against the published static feed.

TripUpdates: stop-level delays, keyed on (trip_id, start_date, stop_sequence + stop_id).
VehiclePositions: only for trips polled through trip_execution.
Anything that does not match the static feed exactly is counted and dropped.
"""
import logging
import threading
from datetime import datetime, timedelta

from google.transit import gtfs_realtime_pb2 as pb

from store import WAW

log = logging.getLogger("rt")
DAY = 86400


def local_midnight(yyyymmdd):
    return datetime.strptime(yyyymmdd, "%Y%m%d").replace(tzinfo=WAW).timestamp()


def hhmm(s):
    h, m = s.split(":")[:2]
    return int(h) * 3600 + int(m) * 60


def wrap(d):
    """Signed difference in seconds, folded into (-12h, 12h]."""
    d %= DAY
    return d - DAY if d > DAY // 2 else d


class Rt:
    def __init__(self, max_age_s=600, horizon_s=14 * 3600):
        self.idx = None
        self.designators = {}
        self.max_age, self.horizon = max_age_s, horizon_s
        self.entries = {}  # (trip_id, start_date) -> {"stops": {seq: {...}}, "vehicle": {...}, "ts": int}
        self.lock = threading.Lock()
        self.last_poll_ok = None
        self.stats = {"rows_seen": 0, "rows_matched": 0, "rows_unmatched": 0, "unmatched_reasons": {},
                      "executions_ok": 0, "executions_unmatched": 0}

    def set_static(self, idx, stops):
        self.idx = idx
        self.designators = {v["designator"]: pid for pid, v in stops.items()}

    def _miss(self, why):
        self.stats["rows_unmatched"] += 1
        r = self.stats["unmatched_reasons"]
        r[why] = r.get(why, 0) + 1

    def start_date(self, tid, seq, now):
        """Pick today or yesterday (service day) by how close the scheduled time at that stop is to now."""
        stop = self.idx.times.get(tid, {}).get(seq)
        if not stop:
            return None
        local = datetime.fromtimestamp(now, WAW).date()
        best = None
        for back in (0, 1):
            d = (local - timedelta(days=back)).strftime("%Y%m%d")
            if not self.idx.active(tid, d):
                continue
            gap = abs(local_midnight(d) + stop[1] - now)
            if gap <= self.horizon and (best is None or gap < best[0]):
                best = (gap, d)
        return best[1] if best else None

    def ingest_departures(self, resp, now):
        """Returns trip_execution candidates: (scheduled_epoch, trip_id, start_date, exec_id, seq)."""
        cands = []
        with self.lock:
            for blk in resp["departures"]:
                pid = self.designators.get(blk["designator"])
                for r in blk["rows"]:
                    self.stats["rows_seen"] += 1
                    tid, seq = str(r["trip_id"]), r["trip_index"]
                    if pid is None:
                        self._miss("unknown stop designator")
                    elif tid not in self.idx.trips:
                        self._miss("trip not in static feed")
                    elif self.idx.stop_at(tid, seq) != pid:
                        self._miss("stop does not match static trip at that sequence")
                    else:
                        sd = self.start_date(tid, seq, now)
                        if sd is None:
                            self._miss("no active service date near now")
                            continue
                        self.stats["rows_matched"] += 1
                        e = self.entries.setdefault((tid, sd), {"stops": {}, "vehicle": None, "ts": now})
                        if r.get("canceled"):
                            e["stops"][seq] = {"stop_id": pid, "skipped": True, "ts": now}
                        elif r.get("is_estimated"):
                            e["stops"][seq] = {"stop_id": pid, "delay": int(r["time_diff"]) * 60, "ts": now}
                            e["ts"] = now
                            if r.get("trip_execution_id"):
                                sched = local_midnight(sd) + self.idx.times[tid][seq][1]
                                cands.append((sched, tid, sd, r["trip_execution_id"], seq))
            self.last_poll_ok = now
        cands.sort()
        return cands

    def ingest_execution(self, tid, sd, raw, now):
        with self.lock:
            idx = self.idx
            t = raw["trip"]["times"]
            nxt = raw.get("next_departure_index")
            ests = raw.get("estimates") or []
            e = self.entries.setdefault((tid, sd), {"stops": {}, "vehicle": None, "ts": now})
            ok = bool(ests) and isinstance(nxt, int) and nxt >= 0
            if ok:
                for i, est in enumerate(ests):
                    if nxt + i >= len(t):
                        ok = False
                        break
                    row = t[nxt + i]
                    seq, pid = row["index"], row["place_id"]
                    if idx.stop_at(tid, seq) != pid:
                        ok = False
                        break
                    arr = est.get("arrival_abs") or est.get("time_abs")
                    if not arr:
                        continue
                    sched = idx.times[tid][seq][1]
                    dep = est.get("time_abs") or arr
                    e["stops"][seq] = {"stop_id": pid, "delay": wrap(hhmm(arr) - sched),
                                       "dep_delay": wrap(hhmm(dep) - sched), "ts": now}
            for c in raw.get("canceled") or []:
                if isinstance(c, int) and idx.stop_at(tid, c):
                    e["stops"][c] = {"stop_id": idx.stop_at(tid, c), "skipped": True, "ts": now}
            v = raw.get("vehicle")
            if isinstance(v, dict) and isinstance(v.get("lat"), (int, float)) and isinstance(v.get("lon"), (int, float)):
                at = bool(raw.get("at_stop"))
                seq = raw.get("vehicle_trip_index") if at else nxt
                if isinstance(seq, int) and idx.stop_at(tid, seq):
                    e["vehicle"] = {"lat": v["lat"], "lon": v["lon"], "seq": seq, "stopped": at, "ts": now}
                else:
                    ok = False
            e["ts"] = now
            self.stats["executions_ok" if ok else "executions_unmatched"] += 1
            return ok

    def _live(self, now):
        keep = {k: v for k, v in self.entries.items() if now - v["ts"] <= self.max_age}
        self.entries = keep
        return keep

    def build(self, now):
        """Returns (trip_updates_bytes, vehicle_positions_bytes) or None before the first successful poll."""
        with self.lock:
            if self.last_poll_ok is None or self.idx is None:
                return None
            live = self._live(now)
            ts = int(self.last_poll_ok)
            out = []
            for kind in ("tu", "vp"):
                f = pb.FeedMessage()
                f.header.gtfs_realtime_version = "2.0"
                f.header.incrementality = pb.FeedHeader.FULL_DATASET
                f.header.timestamp = ts
                for (tid, sd), e in sorted(live.items()):
                    trip_row = self.idx.trips[tid]
                    if kind == "tu" and e["stops"]:
                        ent = f.entity.add()
                        ent.id = f"tu-{tid}-{sd}"
                        tu = ent.trip_update
                        self._trip(tu.trip, tid, trip_row, sd)
                        tu.timestamp = int(e["ts"])
                        for seq in sorted(e["stops"]):
                            s = e["stops"][seq]
                            u = tu.stop_time_update.add()
                            u.stop_sequence, u.stop_id = seq, s["stop_id"]
                            if s.get("skipped"):
                                u.schedule_relationship = pb.TripUpdate.StopTimeUpdate.SKIPPED
                            else:
                                u.arrival.delay = s["delay"]
                                u.departure.delay = s.get("dep_delay", s["delay"])
                    elif kind == "vp" and e["vehicle"]:
                        v = e["vehicle"]
                        ent = f.entity.add()
                        ent.id = f"vp-{tid}-{sd}"
                        self._trip(ent.vehicle.trip, tid, trip_row, sd)
                        ent.vehicle.position.latitude = v["lat"]
                        ent.vehicle.position.longitude = v["lon"]
                        ent.vehicle.current_stop_sequence = v["seq"]
                        ent.vehicle.stop_id = self.idx.stop_at(tid, v["seq"])
                        ent.vehicle.current_status = (pb.VehiclePosition.STOPPED_AT if v["stopped"]
                                                      else pb.VehiclePosition.IN_TRANSIT_TO)
                        ent.vehicle.timestamp = int(v["ts"])
                out.append(f.SerializeToString())
            return tuple(out)

    @staticmethod
    def _trip(td, tid, trip_row, sd):
        td.trip_id, td.route_id, td.start_date = tid, trip_row["route_id"], sd
        td.schedule_relationship = pb.TripDescriptor.SCHEDULED
