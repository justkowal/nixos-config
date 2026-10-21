"""Static crawler. One call to step() makes at most one request and returns the job name or None.

Discovery: /api/timetables/<stop>?date= lists every trip calling at that stop on that date, so a
small set of "cover" stops finds all trips. A stop that no known trip serves is probed to find
lines nobody has seen yet. /api/trip/<id>/<index> is fetched once per trip id and cached.
"""
import logging
import time
from datetime import date as Date
from datetime import timedelta

from guard import SourceError
from store import today_waw, window

log = logging.getLogger("crawl")
DAY = 86400


def hhmm(s):
    h, m = s.split(":")
    return int(h) * 3600 + int(m) * 60


def trip_seconds(raw, index, observed):
    """Absolute seconds from service-day midnight per stop. Anchored on the timetable's own value."""
    out, prev, day = [], -1, 0
    for t in raw["times"]:
        s = hhmm(t["departure_time"]) + day * DAY
        if s < prev:
            day += 1
            s += DAY
        out.append(s)
        prev = s
    pos = next((i for i, t in enumerate(raw["times"]) if t["index"] == index), None)
    if pos is None:
        raise SourceError("anchor index missing in trip")
    shift = observed - out[pos]
    if shift % DAY or out[0] + shift < 0:
        raise SourceError("trip times disagree with the timetable")
    return [s + shift for s in out]


class Crawler:
    def __init__(self, cfg, store, source, clock=time.time):
        self.c, self.st, self.src, self.clock = cfg["static"], store, source, clock
        self.stats = {"trips_rejected": 0, "last_job": None}

    # helpers ----------------------------------------------------------
    def _dates(self, now):
        return window(now, self.c["window_days"])

    def _probe_dates(self, now):
        want = {"wd": None, "sa": None, "su": None}
        for d in self._dates(now):
            wd = Date.fromisoformat(d).weekday()
            k = "wd" if wd < 5 else "sa" if wd == 5 else "su"
            if want[k] is None:
                want[k] = d
        return [d for d in want.values() if d]

    def _ingest(self, pid, date, rows, now):
        s = self.st.s
        s["tt"][f"{pid}|{date}"] = now
        for r in rows:
            tid = str(r["trip_id"])
            days = set(s["seen"].get(tid, []))
            days.add(date)
            s["seen"][tid] = sorted(days)
            s["obs"].setdefault(tid, [r["index"], r["departure"]])
            trip = s["trips"].get(tid)
            if trip:
                have = {x[2]: x[1] for x in trip["stops"]}
                if have.get(r["index"]) != r["departure"]:
                    log.info("trip %s changed upstream, refetching", tid)
                    del s["trips"][tid]
                    s["obs"][tid] = [r["index"], r["departure"]]
                    s["rejected"].pop(tid, None)

    def _prune(self, now):
        s = self.st.s
        old = (today_waw(now) - timedelta(days=3)).isoformat()
        for tid in list(s["seen"]):
            s["seen"][tid] = [d for d in s["seen"][tid] if d >= old]
            if not s["seen"][tid]:
                for k in ("seen", "trips", "obs", "rejected"):
                    s[k].pop(tid, None)
        for k in [k for k in s["tt"] if k.split("|")[1] < old]:
            del s["tt"][k]

    # jobs -------------------------------------------------------------
    def step(self):
        now = self.clock()
        with self.st.lock:
            job = (self._stops(now) or self._trip(now) or self._timetable(now) or self._probe(now))
        if job:
            self._prune(now)
            self.st.save()
        self.stats["last_job"] = job
        return job

    def _stops(self, now):
        s = self.st.s
        if s["stops"] and now - s["stops_checked"] < self.c["stops_check_interval_s"]:
            return None
        rev = self.src.stops_revision()
        s["stops_checked"] = now
        if rev != s["stops_rev"] or not s["stops"]:
            s["stops"] = self.src.stops(rev)
            s["stops_rev"] = rev
            s["cover"] = [p for p in s["cover"] if p in s["stops"]]
        for p in self.c["seed_stops"]:
            if p in s["stops"] and p not in s["cover"]:
                s["cover"].append(p)
        return "stops"

    def _trip(self, now):
        s = self.st.s
        retry = self.c["rejected_retry_s"]
        pending = sorted(t for t in s["seen"] if t not in s["trips"] and now - s["rejected"].get(t, 0) > retry)
        if not pending:
            return None
        tid = pending[0]
        idx, obs = s["obs"][tid]
        try:
            raw = self.src.trip(tid, idx)
            secs = trip_seconds(raw, idx, obs)
        except SourceError as e:
            s["rejected"][tid] = now
            self.stats["trips_rejected"] += 1
            log.warning("trip %s rejected: %s", tid, e)
            return "trip-rejected"
        s["trips"][tid] = {"line": str(raw["line"].get("name", "")), "headsign": raw["direction"],
                           "stops": [[t["place_id"], secs[i], t["index"]] for i, t in enumerate(raw["times"])]}
        return "trip"

    def _timetable(self, now):
        s = self.st.s
        dates = self._dates(now)
        stale = self.c["tt_refresh_days"] * DAY
        for pid in s["cover"]:
            for d in dates:
                ts = s["tt"].get(f"{pid}|{d}")
                if ts is None or (d > dates[0] and now - ts > stale):
                    self._ingest(pid, d, self.src.timetable(pid, d), now)
                    return "timetable"
        return None

    def _probe(self, now):
        s = self.st.s
        today = self._dates(now)[0]
        pd = s["probe_day"]
        if pd["date"] != today:
            pd.update(date=today, n=0)
        if pd["n"] >= self.c["probe_per_day"]:
            return None
        served = self.st.served_stops()
        skip = served | set(s["cover"])
        retry = self.c["probe_retry_days"] * DAY
        cand = [p for p, v in s["stops"].items()
                if p not in skip and now - s["probe"].get(p, {}).get("ts", 0) > retry]
        if not cand:
            return None
        cand.sort(key=lambda p: (not s["stops"][p]["station"], s["stops"][p]["name"], p))
        pid = cand[0]
        for d in self._probe_dates(now):
            key = f"{pid}|{d}"
            if key in s["tt"]:
                continue
            rows = self.src.timetable(pid, d)
            pd["n"] += 1
            self._ingest(pid, d, rows, now)
            if rows:
                s["cover"].append(pid)
                s["probe"][pid] = {"ts": now, "empty": False}
            elif all(f"{pid}|{x}" in s["tt"] for x in self._probe_dates(now)):
                s["probe"][pid] = {"ts": now, "empty": True}
            return "probe"
        s["probe"][pid] = {"ts": now, "empty": True}
        return "probe"
