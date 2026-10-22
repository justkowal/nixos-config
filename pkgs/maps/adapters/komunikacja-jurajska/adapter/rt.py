"""GTFS-RT from the kiedyPrzyjedzie boards, attached to the OPERATOR-based static feed.

The two sources use different ids, so a live trip is attached by content: same line, same day type,
and the same (stop name, minute) pairs. The match is made once per (live trip id, day type) and cached.
No match means no realtime for that trip; nothing is guessed.
"""
import logging
import threading
from datetime import datetime, timedelta

from google.transit import gtfs_realtime_pb2 as pb

from calpl import day_type
from opsite import norm
from store import WAW

log = logging.getLogger("rt")
DAY = 86400
MAP_RETRY_S = 86400


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
    def __init__(self, mapping, max_age_s=600, horizon_s=14 * 3600, min_match=0.8):
        self.idx = None
        self.kp_stops = {}
        self.map = mapping
        self.max_age, self.horizon, self.min_match = max_age_s, horizon_s, min_match
        self.entries = {}  # (op trip id, start_date) -> {"stops": {seq: {...}}, "vehicle": {...}, "ts": int}
        self.lock = threading.Lock()
        self.last_poll_ok = None
        self.stats = {"rows_seen": 0, "rows_matched": 0, "rows_unmatched": 0, "unmatched_reasons": {},
                      "trips_mapped": 0, "trips_unmapped": 0, "executions_ok": 0, "executions_unmatched": 0}

    def set_static(self, idx, kp_stops):
        self.idx, self.kp_stops = idx, kp_stops
        self.designators = {v["designator"]: pid for pid, v in kp_stops.items()}

    def _miss(self, why):
        self.stats["rows_unmatched"] += 1
        r = self.stats["unmatched_reasons"]
        r[why] = r.get(why, 0) + 1

    # mapping -------------------------------------------------------------
    def _entry(self, kp_tid, dt, now):
        e = self.map.get(f"{kp_tid}|{dt}")
        if e is None:
            return None
        if e["op"] is None and now - e["ts"] > MAP_RETRY_S:
            return None
        if e["op"] is not None and e["op"] not in self.idx.trips:
            return None
        return e

    def map_trip(self, kp_tid, raw, dt, now):
        """Match a kiedyPrzyjedzie trip (the /api/trip payload) to one operator trip of the given day type."""
        line = str(raw["line"].get("name", ""))
        kp = {}
        for t in raw["times"]:
            kp[(norm(t["stop_name"]), (hhmm(t["departure_time"]) // 60) % 1440)] = t["index"]
        scored = []
        for tid in self.idx.by_line.get(line, []):
            if not self.idx.trips[tid]["service_id"].startswith(dt + "-"):
                continue
            sig = self.idx.sig[tid]
            common = [k for k in kp if k in sig]
            scored.append((len(common) / max(1, min(len(kp), len(sig))), tid, common))
        scored.sort(reverse=True)
        best = scored[0] if scored else None
        ok = best and best[0] >= self.min_match and (len(scored) < 2 or scored[1][0] < best[0])
        entry = {"op": best[1] if ok else None, "ts": now,
                 "seq": {str(kp[k]): self.idx.sig[best[1]][k] for k in best[2]} if ok else {}}
        self.stats["trips_mapped" if ok else "trips_unmapped"] += 1
        self.map[f"{kp_tid}|{dt}"] = entry
        return entry

    # ingestion -------------------------------------------------------------
    def _date_for(self, kp_tid, kp_index, now, need):
        """Best (start_date, op trip id, seq map entry) among today and yesterday, or None."""
        local = datetime.fromtimestamp(now, WAW).date()
        best = None
        for back in (0, 1):
            d = local - timedelta(days=back)
            dt, ds = day_type(d), d.strftime("%Y%m%d")
            e = self._entry(kp_tid, dt, now)
            if e is None:
                need.add((kp_tid, kp_index, dt))
                continue
            if e["op"] is None or not self.idx.active(e["op"], ds):
                continue
            seq = e["seq"].get(str(kp_index))
            stop = self.idx.times.get(e["op"], {}).get(seq)
            if seq is None or not stop:
                continue
            gap = abs(local_midnight(ds) + stop[1] - now)
            if gap <= self.horizon and (best is None or gap < best[0]):
                best = (gap, ds, e, seq)
        return best

    def ingest_departures(self, resp, now):
        """Returns (execution candidates, mappings still needed).

        candidate = (scheduled epoch, kp trip id, kp index, execution id, op trip id, start_date)
        need = {(kp trip id, kp index, day type)}
        """
        cands, need = [], set()
        cand_keys = set()
        with self.lock:
            for blk in resp["departures"]:
                pid = self.designators.get(blk["designator"])
                for r in blk["rows"]:
                    self.stats["rows_seen"] += 1
                    ktid, kidx = str(r["trip_id"]), r["trip_index"]
                    if pid is None:
                        self._miss("unknown stop designator")
                        continue
                    if not r.get("is_estimated") and not r.get("canceled"):
                        continue  # schedule only, nothing to say
                    b = self._date_for(ktid, kidx, now, need)
                    if b is None:
                        self._miss("no operator trip matched (yet)")
                        continue
                    _, sd, e, seq = b
                    stop_name = self.idx.stops[self.idx.stop_at(e["op"], seq)]["stop_name"]
                    if norm(stop_name) != norm(self.kp_stops[pid]["name"]):
                        self._miss("stop name differs at the matched sequence")
                        continue
                    self.stats["rows_matched"] += 1
                    en = self.entries.setdefault((e["op"], sd), {"stops": {}, "vehicle": None, "ts": now})
                    sid = self.idx.stop_at(e["op"], seq)
                    if r.get("canceled"):
                        en["stops"][seq] = {"stop_id": sid, "skipped": True, "ts": now}
                    else:
                        en["stops"][seq] = {"stop_id": sid, "delay": int(r["time_diff"]) * 60, "ts": now}
                        en["ts"] = now
                        if r.get("trip_execution_id"):
                            key = (ktid, r["trip_execution_id"])
                            if key not in cand_keys:
                                cand_keys.add(key)
                                sched = local_midnight(sd) + self.idx.times[e["op"]][seq][1]
                                cands.append((sched, ktid, kidx, r["trip_execution_id"], e["op"], sd))
            self.last_poll_ok = now
        cands.sort()
        return cands, need

    def ingest_execution(self, ktid, op_tid, sd, raw, now):
        with self.lock:
            idx = self.idx
            dt = day_type(datetime.strptime(sd, "%Y%m%d").date())
            e = self._entry(ktid, dt, now)
            if e is None or e["op"] != op_tid:
                self.stats["executions_unmatched"] += 1
                return False
            seqmap = e["seq"]
            en = self.entries.setdefault((op_tid, sd), {"stops": {}, "vehicle": None, "ts": now})
            t = raw["trip"]["times"]
            nxt = raw.get("next_departure_index")
            ok = True
            ests = raw.get("estimates") or []
            if ests and isinstance(nxt, int) and nxt >= 0:
                for i, est in enumerate(ests):
                    if nxt + i >= len(t):
                        break
                    seq = seqmap.get(str(t[nxt + i]["index"]))
                    arr = est.get("arrival_abs") or est.get("time_abs")
                    if seq is None or not arr:
                        continue
                    sched = idx.times[op_tid][seq][1]
                    dep = est.get("time_abs") or arr
                    en["stops"][seq] = {"stop_id": idx.stop_at(op_tid, seq), "delay": wrap(hhmm(arr) - sched),
                                        "dep_delay": wrap(hhmm(dep) - sched), "ts": now}
            for c in raw.get("canceled") or []:
                seq = seqmap.get(str(c)) if isinstance(c, int) else None
                if seq is not None:
                    en["stops"][seq] = {"stop_id": idx.stop_at(op_tid, seq), "skipped": True, "ts": now}
            v = raw.get("vehicle")
            if isinstance(v, dict) and isinstance(v.get("lat"), (int, float)) and isinstance(v.get("lon"), (int, float)):
                at = bool(raw.get("at_stop"))
                kidx = raw.get("vehicle_trip_index") if at else nxt
                seq = seqmap.get(str(kidx))
                en["vehicle"] = {"lat": v["lat"], "lon": v["lon"], "seq": seq, "stopped": at, "ts": now}
            en["ts"] = now
            self.stats["executions_ok" if ok else "executions_unmatched"] += 1
            return ok

    # output -----------------------------------------------------------------
    def _live(self, now):
        self.entries = {k: v for k, v in self.entries.items() if now - v["ts"] <= self.max_age}
        return self.entries

    def build(self, now):
        """Returns (trip_updates_bytes, vehicle_positions_bytes) or None before the first successful poll."""
        with self.lock:
            if self.last_poll_ok is None or self.idx is None:
                return None
            live = self._live(now)
            out = []
            for kind in ("tu", "vp"):
                f = pb.FeedMessage()
                f.header.gtfs_realtime_version = "2.0"
                f.header.incrementality = pb.FeedHeader.FULL_DATASET
                f.header.timestamp = int(self.last_poll_ok)
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
                        if v.get("seq") is not None:
                            ent.vehicle.current_stop_sequence = v["seq"]
                            ent.vehicle.stop_id = self.idx.stop_at(tid, v["seq"])
                        ent.vehicle.current_status = (pb.VehiclePosition.STOPPED_AT if v["stopped"]
                                                      else pb.VehiclePosition.IN_TRANSIT_TO)
                        ent.vehicle.timestamp = int(v["ts"])
                        ent.vehicle.vehicle.id = f"kj-{tid}"
                        ent.vehicle.vehicle.label = trip_row.get("route_short_name") or trip_row.get("trip_short_name") or "KJ"
                out.append(f.SerializeToString())
            return tuple(out)

    @staticmethod
    def _trip(td, tid, trip_row, sd):
        td.trip_id, td.route_id, td.start_date = tid, trip_row["route_id"], sd
        td.schedule_relationship = pb.TripDescriptor.SCHEDULED
