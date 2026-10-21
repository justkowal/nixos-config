"""Crawl state: stops, trips, the dates each trip was seen on. One JSON file, written atomically."""
import json
import os
import threading
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

WAW = ZoneInfo("Europe/Warsaw")


def today_waw(now):
    return datetime.fromtimestamp(now, WAW).date()


def window(now, days):
    d0 = today_waw(now)
    return [(d0 + timedelta(days=i)).isoformat() for i in range(days)]


class Store:
    def __init__(self, path):
        self.path = path
        self.lock = threading.RLock()
        self.s = {"stops_rev": None, "stops_checked": 0, "stops": {}, "trips": {}, "seen": {},
                  "obs": {}, "tt": {}, "probe": {}, "cover": [], "probe_day": {"date": None, "n": 0},
                  "rejected": {}}
        try:
            with open(path) as f:
                self.s.update(json.load(f))
        except (OSError, ValueError):
            pass

    def save(self):
        with self.lock:
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.s, f, separators=(",", ":"))
            os.replace(tmp, self.path)

    def served_stops(self):
        out = set()
        for t in self.s["trips"].values():
            out.update(x[0] for x in t["stops"])
        return out

    def coverage(self):
        stops = self.s["stops"]
        if not stops:
            return {"stops_total": 0, "stops_on_known_trips": 0, "stops_probed_empty": 0, "ratio": 0.0}
        served = self.served_stops() & stops.keys()
        empty = {p for p, v in self.s["probe"].items() if v.get("empty")} - served
        known = len(served) + len(empty)
        return {"stops_total": len(stops), "stops_on_known_trips": len(served),
                "stops_probed_empty": len(empty), "ratio": round(known / len(stops), 3)}
