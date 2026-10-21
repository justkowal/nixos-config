"""Cut a GTFS zip down to the service dates in [today, today + days) and drop everything no longer referenced.

    trim_gtfs.py in.zip out.zip days [YYYYMMDD]

Ids are not changed, so realtime feeds keep matching. Streams the big tables, so a 300 MB stop_times.txt is fine.
"""
import csv
import datetime
import io
import sys
import zipfile
from zoneinfo import ZoneInfo


def rows(z, name):
    with z.open(name) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig", newline=""))


def header(z, name):
    with z.open(name) as f:
        return next(csv.reader(io.TextIOWrapper(f, encoding="utf-8-sig", newline="")))


def trim(zin, zout, days, start=None):
    z = zipfile.ZipFile(zin)
    names = set(z.namelist())
    lo = start or datetime.datetime.now(ZoneInfo("Europe/Warsaw")).strftime("%Y%m%d")
    hi = (datetime.datetime.strptime(lo, "%Y%m%d") + datetime.timedelta(days=days - 1)).strftime("%Y%m%d")
    inside = lambda d: lo <= d <= hi

    cal, cal_dates, active = [], [], set()
    if "calendar.txt" in names:
        for r in rows(z, "calendar.txt"):
            if r["end_date"] >= lo and r["start_date"] <= hi:
                r["start_date"], r["end_date"] = max(r["start_date"], lo), min(r["end_date"], hi)
                cal.append(r)
                active.add(r["service_id"])
    if "calendar_dates.txt" in names:
        for r in rows(z, "calendar_dates.txt"):
            if inside(r["date"]):
                cal_dates.append(r)
                if r["exception_type"] == "1":
                    active.add(r["service_id"])

    trips = [r for r in rows(z, "trips.txt") if r["service_id"] in active]
    trip_ids = {r["trip_id"] for r in trips}
    route_ids = {r["route_id"] for r in trips}
    shape_ids = {r["shape_id"] for r in trips if r.get("shape_id")}

    out = zipfile.ZipFile(zout, "w", zipfile.ZIP_DEFLATED, compresslevel=6)

    def put(name, fields, it):
        buf = io.StringIO()
        w = csv.DictWriter(buf, fieldnames=fields, lineterminator="\n", extrasaction="ignore")
        w.writeheader()
        with out.open(name, "w") as f:
            n = 0
            for r in it:
                w.writerow(r)
                n += 1
                if buf.tell() > 1 << 20:
                    f.write(buf.getvalue().encode())
                    buf.seek(0), buf.truncate()
            f.write(buf.getvalue().encode())
        return n

    stop_ids = set()

    def times():
        for r in rows(z, "stop_times.txt"):
            if r["trip_id"] in trip_ids:
                stop_ids.add(r["stop_id"])
                yield r

    n_times = put("stop_times.txt", header(z, "stop_times.txt"), times())
    put("trips.txt", header(z, "trips.txt"), trips)
    if "calendar.txt" in names:
        put("calendar.txt", header(z, "calendar.txt"), cal)
    if "calendar_dates.txt" in names:
        put("calendar_dates.txt", header(z, "calendar_dates.txt"), cal_dates)

    allstops = list(rows(z, "stops.txt"))
    parents = {s["parent_station"] for s in allstops if s["stop_id"] in stop_ids and s.get("parent_station")}
    put("stops.txt", header(z, "stops.txt"), (s for s in allstops if s["stop_id"] in stop_ids or s["stop_id"] in parents))
    put("routes.txt", header(z, "routes.txt"), (r for r in rows(z, "routes.txt") if r["route_id"] in route_ids))
    if "shapes.txt" in names:
        put("shapes.txt", header(z, "shapes.txt"), (r for r in rows(z, "shapes.txt") if r["shape_id"] in shape_ids))
    done = {"stop_times.txt", "trips.txt", "calendar.txt", "calendar_dates.txt", "stops.txt", "routes.txt", "shapes.txt"}
    for n in names - done:
        if n.endswith(".txt") and not n.endswith("_ext.txt"):  # the metropolis ext tables are not GTFS and are large
            out.writestr(n, z.read(n))
    out.close()
    return {"window": [lo, hi], "services": len(active), "trips": len(trips), "stop_times": n_times, "stops": len(stop_ids), "routes": len(route_ids)}


if __name__ == "__main__":
    print(trim(sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else None))
