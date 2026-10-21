"""Build the static GTFS zip from the crawl state, and read it back as an index for matching realtime."""
import csv
import hashlib
import io
import zipfile

from store import today_waw

HOME_URL = "https://komunikacjajurajska.kiedyprzyjedzie.pl/"
AGENCY_NAME = "Jurajski Związek Powiatowo-Gminny Komunikacja Jurajska"

LICENSE = """Komunikacja Jurajska GTFS, derived feed for personal use only.

Source: public passenger information pages of the operator, served by kiedyPrzyjedzie.pl
(komunikacjajurajska.kiedyprzyjedzie.pl). Timetable data (c) Jurajski Zwiazek Powiatowo-Gminny
"Komunikacja Jurajska". Stop names and coordinates come from the same service.

This feed is NOT an official publication of the operator. It was converted by a personal adapter,
is used only inside a private network for journey planning, and must not be published,
redistributed or sold.

Known limits: only trips the crawler has discovered are present (see feed_version, the suffix
"cov" is the share of stops known to be covered). Times have one-minute resolution, arrival equals
departure at every stop. There are no shapes. Calendar dates are the dates on which the
operator's pages listed the trip, within a rolling window.
"""


def _csv(rows, header):
    b = io.StringIO()
    w = csv.writer(b, lineterminator="\n")
    w.writerow(header)
    w.writerows(rows)
    return b.getvalue().encode()


def gtfs_time(s):
    return "%02d:%02d:%02d" % (s // 3600, s % 3600 // 60, s % 60)


def build(store, now, coverage):
    """Returns (zip_bytes, stats). Deterministic for the same input."""
    s = store.s
    today = today_waw(now)
    first = today.isoformat()
    stops, trips, drop = s["stops"], [], {"no_dates": 0, "unknown_stop": 0, "short": 0}
    for tid in sorted(s["trips"], key=int):
        t = s["trips"][tid]
        dates = [d for d in s["seen"].get(tid, []) if d >= first]
        if not dates:
            drop["no_dates"] += 1
        elif len(t["stops"]) < 2:
            drop["short"] += 1
        elif any(x[0] not in stops for x in t["stops"]):
            drop["unknown_stop"] += 1
        else:
            trips.append((tid, t, dates))
    if not trips:
        return None, {"trips": 0, "dropped": drop}

    used = sorted({x[0] for _, t, _ in trips for x in t["stops"]})
    lines = sorted({t["line"] for _, t, _ in trips})
    all_dates = sorted({d for _, _, ds in trips for d in ds})
    digest = hashlib.sha1(repr([(tid, t["stops"], ds) for tid, t, ds in trips]).encode()).hexdigest()[:8]
    version = "%s-%s-cov%d" % (all_dates[0].replace("-", ""), digest, round(coverage["ratio"] * 100))

    files = {
        "agency.txt": _csv([["KJ", AGENCY_NAME, HOME_URL, "Europe/Warsaw", "pl"]],
                           ["agency_id", "agency_name", "agency_url", "agency_timezone", "agency_lang"]),
        "stops.txt": _csv([[p, stops[p]["name"], "%.6f" % stops[p]["lat"], "%.6f" % stops[p]["lon"]] for p in used],
                          ["stop_id", "stop_name", "stop_lat", "stop_lon"]),
        "routes.txt": _csv([["line-" + ln, "KJ", ln, 3] for ln in lines],
                           ["route_id", "agency_id", "route_short_name", "route_type"]),
        "trips.txt": _csv([["line-" + t["line"], "svc-" + tid, tid, t["headsign"]] for tid, t, _ in trips],
                          ["route_id", "service_id", "trip_id", "trip_headsign"]),
        "stop_times.txt": _csv([[tid, gtfs_time(x[1]), gtfs_time(x[1]), x[0], x[2]]
                                for tid, t, _ in trips for x in t["stops"]],
                               ["trip_id", "arrival_time", "departure_time", "stop_id", "stop_sequence"]),
        "calendar_dates.txt": _csv([["svc-" + tid, d.replace("-", ""), 1] for tid, _, ds in trips for d in ds],
                                   ["service_id", "date", "exception_type"]),
        "feed_info.txt": _csv([["kowal-lab maps adapter (personal, internal)", HOME_URL, "pl",
                                all_dates[0].replace("-", ""), all_dates[-1].replace("-", ""), version,
                                "hopkuba@gmail.com"]],
                              ["feed_publisher_name", "feed_publisher_url", "feed_lang", "feed_start_date",
                               "feed_end_date", "feed_version", "feed_contact_email"]),
        "attributions.txt": _csv(
            [["a1", "Jurajski Związek Powiatowo-Gminny Komunikacja Jurajska", 0, 1, 1, HOME_URL],
             ["a2", "kiedyPrzyjedzie.pl (passenger information service, data source)", 1, 0, 0,
              "https://kiedyprzyjedzie.pl/"]],
            ["attribution_id", "organization_name", "is_producer", "is_operator", "is_authority",
             "attribution_url"]),
        "license.txt": LICENSE.encode(),
    }
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(files):
            zi = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, files[name])
    stats = {"trips": len(trips), "stops": len(used), "routes": len(lines), "dropped": drop,
             "feed_version": version, "feed_start": all_dates[0], "feed_end": all_dates[-1]}
    return buf.getvalue(), stats


class Index:
    """The published feed, read back. Realtime is matched against this, never against raw crawl state."""

    def __init__(self, data):
        z = zipfile.ZipFile(io.BytesIO(data))

        def rows(n):
            return list(csv.DictReader(io.TextIOWrapper(z.open(n), encoding="utf-8")))

        self.routes = {r["route_id"]: r for r in rows("routes.txt")}
        self.trips = {r["trip_id"]: r for r in rows("trips.txt")}
        self.stops = {r["stop_id"]: r for r in rows("stops.txt")}
        self.times = {}
        for r in rows("stop_times.txt"):
            h, m, sec = (int(x) for x in r["departure_time"].split(":"))
            self.times.setdefault(r["trip_id"], {})[int(r["stop_sequence"])] = (r["stop_id"], h * 3600 + m * 60 + sec)
        self.dates = {}
        for r in rows("calendar_dates.txt"):
            if r["exception_type"] == "1":
                self.dates.setdefault(r["service_id"], set()).add(r["date"])
        self.version = rows("feed_info.txt")[0]["feed_version"]
        self.feed_end = rows("feed_info.txt")[0]["feed_end_date"]

    def active(self, trip_id, yyyymmdd):
        t = self.trips.get(trip_id)
        return bool(t) and yyyymmdd in self.dates.get(t["service_id"], ())

    def stop_at(self, trip_id, seq):
        x = self.times.get(trip_id, {}).get(seq)
        return x[0] if x else None
