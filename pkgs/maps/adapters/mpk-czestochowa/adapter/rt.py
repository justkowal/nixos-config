"""Realtime: liveMPK websocket (/vehicles_exec) to GTFS-RT TripUpdates and VehiclePositions.

The source's run foreignID equals the static trip_id. A run is only emitted when its
stop list and scheduled times agree with the static trip, otherwise it is dropped.
"""
import datetime as dt
import json
import logging
import threading
import time

from google.transit import gtfs_realtime_pb2 as pb

from guard import Blocked, fetch
from static import TZ

log = logging.getLogger("rt")


def epoch(iso):
    return dt.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()


def match_run(run, index):
    """Return (trip_row, stop_times, start_date, base_epoch) or (None, reason)."""
    tid = str(run.get("foreignID"))
    trip = index.trips.get(tid)
    if not trip:
        return None, "unknown trip"
    day = dt.datetime.fromisoformat(run["day"].replace("Z", "+00:00")).astimezone(TZ).date()
    if not index.service_active(trip["service_id"], day):
        return None, "service not active on run day"
    times, stops = index.times[tid], run.get("runStops") or []
    if len(times) != len(stops):
        return None, "stop count differs"
    base = (dt.datetime.combine(day, dt.time(12), TZ) - dt.timedelta(hours=12)).timestamp()
    bad = sum(abs(epoch(s["time"]) - (base + t[2])) > 60 for s, t in zip(stops, times))
    if bad > 0.05 * len(stops):
        return None, "scheduled times differ"
    return (trip, times, day.strftime("%Y%m%d"), base), None


def build(vehicles, meta, index, now, max_pos_age=300):
    """vehicles: list of vehiclesStatus items. Returns (trip_updates, vehicle_positions, stats)."""
    tu, vp = pb.FeedMessage(), pb.FeedMessage()
    for f in (tu, vp):
        f.header.gtfs_realtime_version = "2.0"
        f.header.incrementality = pb.FeedHeader.FULL_DATASET
        f.header.timestamp = int(now)
    stats = {"vehicles": 0, "matched": 0, "unmatched": {}}
    for v in vehicles:
        pos = v.get("lastPosition")
        run = v.get("currentRun")
        if not pos or not run:
            continue
        ts = epoch(pos["dateTime"])
        if now - ts > max_pos_age:
            continue
        stats["vehicles"] += 1
        m, why = match_run(run, index)
        m_ = meta.get(v["vehicleID"], {})
        ent = vp.entity.add()
        ent.id = f"vp-{pos['taborNo']}"
        p = ent.vehicle
        p.position.latitude, p.position.longitude = pos["latitude"], pos["longitude"]
        p.timestamp = int(ts)
        p.vehicle.id = str(pos["taborNo"])
        p.vehicle.label = m_.get("sideNo", str(pos["taborNo"]))
        if m_.get("regNo"):
            p.vehicle.license_plate = m_["regNo"]
        if not m:
            stats["unmatched"][why] = stats["unmatched"].get(why, 0) + 1
            continue
        stats["matched"] += 1
        trip, times, start_date, base = m
        stops = run["runStops"]
        last = max((i for i, s in enumerate(stops) if s.get("arrivalTime")), default=None)
        for d in (p.trip,):
            d.trip_id, d.route_id, d.start_date = trip["trip_id"], trip["route_id"], start_date
            if trip.get("direction_id") != "":
                d.direction_id = int(trip["direction_id"])
        nxt = (last + 1) if last is not None else 0
        if nxt < len(times):
            p.current_stop_sequence, p.stop_id = times[nxt][0], times[nxt][1]
            p.current_status = pb.VehiclePosition.IN_TRANSIT_TO
        if last is None:
            continue
        t = tu.entity.add()
        t.id = f"tu-{trip['trip_id']}"
        u = t.trip_update
        u.trip.trip_id, u.trip.route_id, u.trip.start_date = trip["trip_id"], trip["route_id"], start_date
        if trip.get("direction_id") != "":
            u.trip.direction_id = int(trip["direction_id"])
        u.vehicle.CopyFrom(p.vehicle)
        u.timestamp = int(ts)
        cur = 0
        for i, (seq, sid, arr, dep) in enumerate(times):
            s = stops[i]
            if s.get("arrivalTime"):
                a = int(epoch(s["arrivalTime"]) - (base + arr))
                dl = int(epoch(s["departureTime"]) - (base + dep)) if s.get("departureTime") else a
                cur = dl
            elif i <= last:
                continue
            else:
                a = dl = cur
            su = u.stop_time_update.add()
            su.stop_sequence, su.stop_id = seq, sid
            su.arrival.delay, su.departure.delay = a, dl
        u.delay = cur
    return tu, vp, stats


class RtClient:
    def __init__(self, cfg, guard, get_index):
        self.cfg, self.guard, self.get_index = cfg, guard, get_index
        self.rt = cfg["realtime"]
        self.sio = None
        self.meta, self.meta_at = {}, 0
        self.all_ids, self.sub = [], None
        self.mode, self.last_discover = "discover", 0
        self.last_msg = 0
        self.connected_at = 0
        self.state = "starting"
        self.lock = threading.Lock()
        self.out = (b"", b"")
        self.stats = {}
        self.stop = threading.Event()

    def empty(self, now=None):
        f = pb.FeedMessage()
        f.header.gtfs_realtime_version = "2.0"
        f.header.incrementality = pb.FeedHeader.FULL_DATASET
        f.header.timestamp = int(now or time.time())
        return f.SerializeToString()

    def serve(self, which):
        with self.lock:
            fresh = time.time() - self.last_msg <= self.rt["stale_after_s"]
            return self.out[which] if fresh and self.out[which] else self.empty()

    def _on_status(self, data):
        now = time.time()
        index = self.get_index()
        if index is None:
            return
        ns = "/vehicles_exec"
        if self.mode == "discover":
            ids = [v["vehicleID"] for v in data
                   if v.get("lastPosition") and now - epoch(v["lastPosition"]["dateTime"]) <= self.rt["max_position_age_s"]]
            self.sub = ids
            self.mode = "track"
            self.last_discover = now
            self.sio.emit("vehicles", ids, namespace=ns)
        tu, vp, stats = build(data, self.meta, index, now, self.rt["max_position_age_s"])
        with self.lock:
            self.out = (tu.SerializeToString(), vp.SerializeToString())
            self.stats = stats
            self.last_msg = now

    def _ensure_meta(self):
        if time.time() - self.meta_at < self.rt["vehicle_list_refresh_s"] and self.meta:
            return
        c = self.cfg["source"]
        _, _, body = fetch(self.guard, c["live_base"] + "/api/vehicles", c["user_agent"], expect_json=True)
        rows = json.loads(body)
        self.meta = {r["vehicleID"]: r for r in rows}
        self.all_ids = list(self.meta)
        self.meta_at = time.time()

    def _connect(self):
        import socketio
        self.guard.acquire()
        ns = "/vehicles_exec"
        sio = socketio.Client(reconnection=False)
        sio.on("vehiclesStatus", self._on_status, namespace=ns)
        try:
            sio.connect(self.cfg["source"]["live_base"], namespaces=[ns], transports=["websocket"],
                        headers={"User-Agent": self.cfg["source"]["user_agent"]})
        except Exception as e:
            self.guard.record(error=True)
            raise OSError(f"websocket connect failed: {e}") from e
        self.guard.record(status=101)
        self.sio = sio
        self.mode = "discover"
        self.connected_at = time.time()
        sio.emit("vehicles", self.all_ids, namespace=ns)

    def _disconnect(self):
        if self.sio is not None:
            try:
                self.sio.disconnect()
            except Exception:
                pass
            self.sio = None

    def run(self):
        while not self.stop.is_set():
            wait = 1
            try:
                index = self.get_index()
                if index is None or not index.in_service(time.time()):
                    self._disconnect()
                    self.state = "idle"
                    wait = 60
                else:
                    self._ensure_meta()
                    if self.sio is None or not self.sio.connected:
                        if self.sio is not None and time.time() - self.connected_at < 30:
                            self.guard.record(error=True)
                        self._disconnect()
                        self._connect()
                    now = time.time()
                    ref = max(self.last_msg, self.connected_at)
                    if now - ref > self.rt["silence_reconnect_s"]:
                        log.warning("no data for %ds, reconnecting", now - ref)
                        self.guard.record(error=True)
                        self._disconnect()
                    elif self.mode == "track" and now - self.last_discover > self.rt["discover_interval_s"]:
                        self.mode = "discover"
                        self.sio.emit("vehicles", self.all_ids, namespace="/vehicles_exec")
                    self.state = "streaming"
            except Blocked as e:
                log.error("%s", e)
                self._disconnect()
                self.state = "blocked"
                wait = 300
            except OSError as e:
                log.warning("%s", e)
                self.state = "error"
                wait = 5
            self.stop.wait(wait)
        self._disconnect()
