"""Static crawler. One call to step() makes at most one request and returns the job name or None.

Sources: the operator site is the timetable source (start page -> line pages -> reverse pages),
kiedyPrzyjedzie provides its stop list (for comparing positions and for realtime) and, once per
line, a yes/no on whether it serves the line (live data possible).
"""
import logging
import time
from datetime import timedelta

import opsite
import recon
from guard import SourceError
from store import today_waw

log = logging.getLogger("crawl")
DAY = 86400


def line_key(line):
    digits = "".join(c for c in line if c.isdigit())
    return (int(digits) if digits else 0, line)


class Crawler:
    def __init__(self, cfg, store, kp, op, clock=time.time):
        self.c, self.st, self.kp, self.op, self.clock = cfg["static"], store, kp, op, clock
        self.stats = {"last_job": None}

    def step(self):
        now = self.clock()
        with self.st.lock:
            job = self._home(now) or self._line(now) or self._kp_stops(now) or self._census(now)
            if job:
                self.st.save()
        self.stats["last_job"] = job
        return job

    # operator ----------------------------------------------------------
    def _home(self, now):
        s = self.st.s
        if s["site_lines"] and now - s["op_home_checked"] < self.c["home_check_interval_s"]:
            return None
        found = self.op.lines()
        s["site_lines"] = {line: url for line, url in found}
        s["op_home_checked"] = now
        for gone in set(s["lines"]) - set(s["site_lines"]):
            log.info("line %s is no longer listed, dropping it", gone)
            del s["lines"][gone]
        return "home"

    def _line(self, now):
        s = self.st.s
        stale = self.c["line_refresh_days"] * DAY
        retry = self.c["fail_retry_s"]
        pend = s.setdefault("pending", {})
        for line in sorted(s["site_lines"], key=line_key):
            f = s["line_fetch"].setdefault(line, {})
            if line in pend:  # main page read, reverse page still to do
                url = pend[line]["reverse_url"]
                try:
                    rev = self.op.line_page(url)
                except SourceError as e:
                    log.warning("reverse page of line %s failed: %s", line, e)
                    rev = None
                    f["fail"] = now
                s["lines"][line] = opsite.line_record(pend.pop(line), rev, (s["site_lines"][line], url), now)
                f["done"] = now
                return "line-rev"
            have = line in s["lines"]
            if have and now - f.get("done", 0) < stale:
                continue
            if now - f.get("fail", 0) < retry and not (have and now - f.get("done", 0) >= stale * 2):
                continue
            try:
                main = self.op.line_page(s["site_lines"][line])
            except SourceError as e:
                f["fail"] = now
                log.warning("line %s page failed: %s", line, e)
                return "line-failed"
            if main["reverse_url"]:
                pend[line] = main
            else:
                s["lines"][line] = opsite.line_record(main, None, (s["site_lines"][line], None), now)
                f["done"] = now
            return "line"
        return None

    # kiedyPrzyjedzie ----------------------------------------------------
    def _kp_stops(self, now):
        s = self.st.s
        if s["kp_stops"] and now - s["kp_checked"] < self.c["stops_check_interval_s"]:
            return None
        if not s["lines"] and not s["kp_stops"]:
            return None  # nothing to compare against yet
        rev = self.kp.stops_revision()
        s["kp_checked"] = now
        if rev != s["kp_rev"] or not s["kp_stops"]:
            s["kp_stops"] = self.kp.stops(rev)
            s["kp_rev"] = rev
        return "kp-stops"

    def _census(self, now):
        s = self.st.s
        if not s["kp_stops"]:
            return None
        names = recon.by_name(s["kp_stops"])
        stale = self.c["census_refresh_days"] * DAY
        today = today_waw(now)
        for line in sorted(s["lines"], key=line_key):
            c = s["kp_lines"].get(line)
            if c and now - c["ts"] < stale:
                continue
            rec = s["lines"][line]
            side = rec["dirs"].get("A") or next(iter(rec["dirs"].values()), None)
            place = None
            for st in (side["stops"] if side else []):
                hits = names.get(opsite.norm(st["name"]))
                if hits:
                    near = recon.nearest_kp(st, names) if st["lat"] is not None else None
                    place = near[1] if near else hits[0][0]
                    break
            if place is None:
                s["kp_lines"][line] = {"known": False, "ts": now, "why": "no stop of the line has a same-name stop there"}
                continue
            days = {c["day"] for d in rec["dirs"].values() for c in d["courses"]}
            wanted = {0, 1, 2, 3, 4} if "wd" in days else {5} if "sa" in days else {6}
            d = today
            while d.weekday() not in wanted:
                d += timedelta(days=1)
            known = self.kp.line_known(place, line, d.isoformat())
            s["kp_lines"][line] = {"known": known, "ts": now, "place": place, "date": d.isoformat()}
            return "census"
        return None
