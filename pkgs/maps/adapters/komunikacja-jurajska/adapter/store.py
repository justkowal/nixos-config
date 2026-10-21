"""Crawl state: operator line records, kiedyPrzyjedzie stops, line census, trip mapping. One JSON file, written atomically."""
import json
import os
import threading
from datetime import datetime
from zoneinfo import ZoneInfo

WAW = ZoneInfo("Europe/Warsaw")


def today_waw(now):
    return datetime.fromtimestamp(now, WAW).date()


class Store:
    def __init__(self, path):
        self.path = path
        self.lock = threading.RLock()
        self.s = {
            "op_home_checked": 0, "site_lines": {},  # line -> [main url]
            "lines": {},  # line -> record from opsite.line_record
            "line_fetch": {},  # line -> {"main": ts, "rev": ts, "fail": ts}
            "kp_rev": None, "kp_checked": 0, "kp_stops": {},
            "kp_lines": {},  # line -> {"known": bool, "ts": ts}
            "map": {},  # "<kp trip id>|<day type>" -> {"op": trip id or None, "seq": {kp index: op seq}, "ts": ts}
            "recon": None,
        }
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
