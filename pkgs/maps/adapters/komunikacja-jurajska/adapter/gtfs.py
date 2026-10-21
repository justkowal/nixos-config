"""Build the static GTFS zip from the operator's timetables, and read it back for matching realtime."""
import csv
import hashlib
import io
import zipfile
from datetime import date

import recon
from calpl import holidays
from opsite import norm
from store import today_waw

HOME_URL = "https://www.komunikacjajurajska.pl/"
AGENCY_NAME = "Jurajski Związek Powiatowo-Gminny Komunikacja Jurajska"
DAYS = {"wd": (1, 1, 1, 1, 1, 0, 0), "sa": (0, 0, 0, 0, 0, 1, 0), "su": (0, 0, 0, 0, 0, 0, 1)}
POSITION_CONFLICT_M = 1000  # beyond this the operator marker is treated as a map error
CONDITIONAL = {"S": "school days only", "H": "school holidays only"}

LICENSE = """Komunikacja Jurajska GTFS, derived feed for personal use only.

Timetables: the operator's public timetable pages (www.komunikacjajurajska.pl), (c) Jurajski Zwiazek
Powiatowo-Gminny "Komunikacja Jurajska". Stop positions: the stop map on the same pages. Live data:
kiedyPrzyjedzie.pl (komunikacjajurajska.kiedyprzyjedzie.pl).

This feed is NOT an official publication of the operator. It was converted by a personal adapter,
is used only inside a private network for journey planning, and must not be published,
redistributed or sold.

Known limits: one-minute resolution, arrival equals departure at every stop, no shapes. Days follow
the operator's three day types (Monday-Friday, Saturday, Sunday and public holidays); Polish public
holidays are computed, not published by the operator. Trips marked S (school days only) or H (school
holidays only) by the operator are present on every day of their type because the school calendar is
not published there; their trip_short_name carries the marker. Where the operator map puts a stop more
than 1 km from every same-name stop on kiedyPrzyjedzie.pl, the kiedyPrzyjedzie position is used and
stated in stop_desc. Stops without a position on the
operator's map and without a same-name stop on kiedyPrzyjedzie.pl are left out of their trips.
"""


def _csv(rows, header):
    b = io.StringIO()
    w = csv.writer(b, lineterminator="\n")
    w.writerow(header)
    w.writerows(rows)
    return b.getvalue().encode()


def gtfs_time(s):
    return "%02d:%02d:%02d" % (s // 3600, s % 3600 // 60, s % 60)


def _d(s):
    return date.fromisoformat(s)


def stop_table(lines):
    """{op_id: {name, lat, lon}} from every marker the operator published, plus name -> ids for id-less stops."""
    stops, by_name = {}, {}
    for rec in lines.values():
        for side in rec["dirs"].values():
            for s in side["stops"]:
                if s["id"] is not None and s["lat"] is not None:
                    stops.setdefault(str(s["id"]), {"name": s["name"], "lat": s["lat"], "lon": s["lon"]})
    for sid, s in stops.items():
        by_name.setdefault(norm(s["name"]), []).append(sid)
    return stops, by_name


def build(store, now, kp_stops=None, kp_lines=None, site_lines=None):
    """Returns (zip_bytes or None, stats). Deterministic for the same input."""
    s = store.s
    lines, kp_stops, kp_lines = s["lines"], kp_stops or {}, kp_lines or s.get("kp_lines", {})
    today = today_waw(now)
    op_stops, by_name = stop_table(lines)
    kp_names, overrides = recon.by_name(kp_stops), {}
    for sid, o in op_stops.items():
        near = recon.nearest_kp(o, kp_names)
        if near and near[0] > POSITION_CONFLICT_M:
            k = kp_stops[near[1]]
            overrides[sid] = {"metres": round(near[0]), "kp_place": near[1], "lat": k["lat"], "lon": k["lon"]}

    def resolve(st):
        """(stop_id, source) for one timetable stop, or None."""
        if st["id"] is not None and st["lat"] is not None:
            return str(st["id"]), "operator map"
        ids = by_name.get(norm(st["name"]), [])
        if len(ids) == 1:
            return ids[0], "operator map (same name)"
        return None

    trips, table, svc = [], [], {}
    for line in sorted(lines, key=lambda x: (len(x), x)):
        rec = lines[line]
        row = {"line": line, "trips": 0, "stops": set(), "conditional": 0, "dropped_stops": 0,
               "kp_known": kp_lines.get(line, {}).get("known"), "problems": list(rec["problems"]), "status": "ok"}
        table.append(row)
        if not rec["valid_from"] or not rec["valid_to"]:
            row["status"] = "no validity period on the page"
            continue
        if _d(rec["valid_to"]) < today:
            row["status"] = "timetable expired " + rec["valid_to"]
            continue
        used = {}
        for dk in sorted(rec["dirs"]):
            side = rec["dirs"][dk]
            ids = [resolve(st) for st in side["stops"]]
            for st, r in zip(side["stops"], ids):
                if r is None:
                    row["dropped_stops"] += 1
            for c in side["courses"]:
                days = ("wd", "sa") if c["day"] == "wdsa" else (c["day"],)
                pts, prev, add = [], -1, 0
                for j, (st, r) in enumerate(zip(side["stops"], ids)):
                    m = c["times"][j]
                    if m is None or r is None:
                        continue
                    t = m * 60 + add
                    if t < prev:
                        add += 86400
                        t += 86400
                    prev = t
                    if pts and pts[-1][1] == r[0]:
                        continue
                    pts.append((j, r[0], t))
                if len(pts) < 2:
                    continue
                for day in days:
                    if day not in DAYS:
                        row["status"] = "partial: unknown day type " + day
                        continue
                    tid = "%s-%s-%s-%02d%02d" % (line, dk, day, pts[0][2] // 3600 % 24, pts[0][2] // 60 % 60)
                    used[tid] = used.get(tid, 0) + 1
                    if used[tid] > 1:
                        tid += "-%d" % used[tid]
                    sid = "%s-%s-%s" % (day, rec["valid_from"].replace("-", ""), rec["valid_to"].replace("-", ""))
                    svc[sid] = (day, rec["valid_from"], rec["valid_to"])
                    sym = ",".join(c["sym"])
                    trips.append((tid, line, sid, side["stops"][pts[-1][0]]["name"], sym, pts))
                    row["trips"] += 1
                    row["stops"].update(p[1] for p in pts)
                    row["conditional"] += bool(set(c["sym"]) & set(CONDITIONAL))
        if not row["trips"]:
            row["status"] = "no usable trips"
    if not trips:
        return None, {"trips": 0, "lines": [], "lines_on_site": site_lines or len(lines)}

    used_stops = sorted({p[1] for t in trips for p in t[5]}, key=lambda x: (len(x), x))
    stop_rows = []
    for sid in used_stops:
        o, ov = op_stops[sid], overrides.get(sid)
        if ov:
            stop_rows.append([sid, o["name"], "%.6f" % ov["lat"], "%.6f" % ov["lon"],
                              "position from kiedyPrzyjedzie.pl, the operator map put this stop %d m away" % ov["metres"]])
        else:
            stop_rows.append([sid, o["name"], "%.6f" % o["lat"], "%.6f" % o["lon"], ""])
    route_rows, seen_routes = [], set()
    for line, rec in sorted(lines.items(), key=lambda x: (len(x[0]), x[0])):
        if any(t[1] == line for t in trips) and line not in seen_routes:
            seen_routes.add(line)
            a = rec["dirs"].get("A")
            route_rows.append(["line-" + line, "KJ", line, a["title"] if a else "", 3])
    cal_rows, cd_rows = [], []
    for sid, (day, vf, vt) in sorted(svc.items()):
        cal_rows.append([sid, *DAYS[day], vf.replace("-", ""), vt.replace("-", "")])
        for y in range(_d(vf).year, _d(vt).year + 1):
            for h in sorted(holidays(y)):
                if not (_d(vf) <= h <= _d(vt)):
                    continue
                wd = h.weekday()
                if (day == "wd" and wd < 5) or (day == "sa" and wd == 5):
                    cd_rows.append([sid, h.strftime("%Y%m%d"), 2])
                elif day == "su" and wd != 6:
                    cd_rows.append([sid, h.strftime("%Y%m%d"), 1])
    trips.sort(key=lambda t: t[0])
    starts = min(_d(v[1]) for v in svc.values())
    ends = max(_d(v[2]) for v in svc.values())
    cov = round(100 * len([r for r in table if r["trips"]]) / max(site_lines or len(lines), 1))
    digest = hashlib.sha1(repr([(t[0], t[5]) for t in trips]).encode()).hexdigest()[:8]
    version = "%s-%s-lines%d" % (starts.strftime("%Y%m%d"), digest, len([r for r in table if r["trips"]]))
    files = {
        "agency.txt": _csv([["KJ", AGENCY_NAME, HOME_URL, "Europe/Warsaw", "pl"]],
                           ["agency_id", "agency_name", "agency_url", "agency_timezone", "agency_lang"]),
        "stops.txt": _csv(stop_rows, ["stop_id", "stop_name", "stop_lat", "stop_lon", "stop_desc"]),
        "routes.txt": _csv(route_rows, ["route_id", "agency_id", "route_short_name", "route_long_name", "route_type"]),
        "trips.txt": _csv([["line-" + t[1], t[2], t[0], t[3], t[4]] for t in trips],
                          ["route_id", "service_id", "trip_id", "trip_headsign", "trip_short_name"]),
        "stop_times.txt": _csv([[t[0], gtfs_time(p[2]), gtfs_time(p[2]), p[1], p[0]] for t in trips for p in t[5]],
                               ["trip_id", "arrival_time", "departure_time", "stop_id", "stop_sequence"]),
        "calendar.txt": _csv(cal_rows, ["service_id", "monday", "tuesday", "wednesday", "thursday", "friday",
                                        "saturday", "sunday", "start_date", "end_date"]),
        "feed_info.txt": _csv([["kowal-lab maps adapter (personal, internal)", HOME_URL, "pl",
                                starts.strftime("%Y%m%d"), ends.strftime("%Y%m%d"), version, "hopkuba@gmail.com"]],
                              ["feed_publisher_name", "feed_publisher_url", "feed_lang", "feed_start_date",
                               "feed_end_date", "feed_version", "feed_contact_email"]),
        "attributions.txt": _csv(
            [["a1", "Jurajski Związek Powiatowo-Gminny Komunikacja Jurajska", 1, 1, 1, HOME_URL]],
            ["attribution_id", "organization_name", "is_producer", "is_operator", "is_authority",
             "attribution_url"]),
        "license.txt": LICENSE.encode(),
    }
    if cd_rows:
        files["calendar_dates.txt"] = _csv(cd_rows, ["service_id", "date", "exception_type"])
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(files):
            zi = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, files[name])
    for r in table:
        r["stops"] = len(r["stops"])
    stats = {"trips": len(trips), "stops": len(used_stops), "routes": len(route_rows), "lines": table,
             "lines_on_site": site_lines or len(lines), "lines_with_trips": len([r for r in table if r["trips"]]),
             "line_coverage_percent": cov, "feed_version": version, "feed_start": starts.isoformat(),
             "feed_end": ends.isoformat(),
             "position_overrides": {k: v for k, v in overrides.items() if k in set(used_stops)}}
    return buf.getvalue(), stats


class Index:
    """The published feed, read back. Realtime is matched against this, never against raw crawl state."""

    def __init__(self, data):
        z = zipfile.ZipFile(io.BytesIO(data))

        def rows(n):
            if n not in z.namelist():
                return []
            return list(csv.DictReader(io.TextIOWrapper(z.open(n), encoding="utf-8")))

        self.routes = {r["route_id"]: r for r in rows("routes.txt")}
        self.trips = {r["trip_id"]: r for r in rows("trips.txt")}
        self.stops = {r["stop_id"]: r for r in rows("stops.txt")}
        self.times, self.sig = {}, {}
        for r in rows("stop_times.txt"):
            h, m, sec = (int(x) for x in r["departure_time"].split(":"))
            self.times.setdefault(r["trip_id"], {})[int(r["stop_sequence"])] = (r["stop_id"], h * 3600 + m * 60 + sec)
            self.sig.setdefault(r["trip_id"], {})[(norm(self.stops[r["stop_id"]]["stop_name"]), (h * 60 + m) % 1440)] = \
                int(r["stop_sequence"])
        self.cal = {r["service_id"]: r for r in rows("calendar.txt")}
        self.exc = {}
        for r in rows("calendar_dates.txt"):
            self.exc.setdefault(r["service_id"], {})[r["date"]] = r["exception_type"]
        self.by_line = {}
        for tid, t in self.trips.items():
            self.by_line.setdefault(self.routes[t["route_id"]]["route_short_name"], []).append(tid)
        info = rows("feed_info.txt")[0]
        self.version, self.feed_end = info["feed_version"], info["feed_end_date"]

    def active(self, trip_id, yyyymmdd):
        t = self.trips.get(trip_id)
        if not t:
            return False
        sid = t["service_id"]
        e = self.exc.get(sid, {}).get(yyyymmdd)
        if e:
            return e == "1"
        c = self.cal.get(sid)
        if not c or not (c["start_date"] <= yyyymmdd <= c["end_date"]):
            return False
        d = date(int(yyyymmdd[:4]), int(yyyymmdd[4:6]), int(yyyymmdd[6:]))
        return c[("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")[d.weekday()]] == "1"

    def stop_at(self, trip_id, seq):
        x = self.times.get(trip_id, {}).get(seq)
        return x[0] if x else None

