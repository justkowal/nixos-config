"""PLK /schedules responses to a static GTFS zip plus a small index the realtime side matches against."""
import csv
import io
import re
import unicodedata
import zipfile
from datetime import date, timedelta

AGENCY_URL = "https://pdp-api.plk-sa.pl/"
LICENSE_TEXT = """Internal use only. Not published, not redistributed.

Timetable data: PKP Polskie Linie Kolejowe S.A., Otwarte Dane Kolejowe API
(https://pdp-api.plk-sa.pl), used under the API terms of use (regulamin) v1.0.
Source: PKP Polskie Linie Kolejowe S.A.

Stop positions are not published by PLK. They are derived from OpenStreetMap
(c) OpenStreetMap contributors, ODbL 1.0, via a local Nominatim instance, or set
manually by the operator of this feed.

Data is informational and approximate; see section 5.5 of the PLK terms.
"""


def trip_id(sid, oid, toid=None):
    t = "%d-%d" % (sid, oid)
    if toid and toid != oid:
        t += "-%d" % toid
    return t


def parse_dur(s):
    """'12:34:00' or '1.02:03:00' to seconds."""
    if s is None:
        return None
    days = 0
    if "." in s.split(":")[0]:
        d, s = s.split(".", 1)
        days = int(d)
    parts = [float(p) for p in s.split(":")]
    parts += [0] * (3 - len(parts))
    return days * 86400 + int(parts[0] * 3600 + parts[1] * 60 + parts[2])


def hms(sec):
    return "%02d:%02d:%02d" % (sec // 3600, sec % 3600 // 60, sec % 60)


def slug(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    return re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_") or "x"


def _csv(header, rows):
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(header)
    w.writerows(rows)
    return buf.getvalue().encode("utf8")


def _is_pass_through(st, cfg):
    if st.get("stopTypeId") in cfg["corridor"]["pass_through_stop_type_ids"]:
        return True
    return "bez zatrzym" in (st.get("stopTypeName") or "").casefold()


def build(responses, geocoder, today, cfg, schedules_version):
    """responses: validated ScheduleResponseDto dicts. Returns (zip_bytes, index, stats)."""
    stats = {"routes_in": 0, "trips": 0, "dropped": {}, "geocode_missing": [], "osm_positions": 0,
             "override_positions": 0}

    def drop(why):
        stats["dropped"][why] = stats["dropped"].get(why, 0) + 1

    names, carriers, routes = {}, {}, {}
    for r in responses:
        d = r.get("dictionaries") or {}
        for s in (d.get("stations") or {}).values():
            if s.get("name"):
                names[s["id"]] = s["name"]
        carriers.update(d.get("carriers") or {})
        for rt in r["routes"] or []:
            key = (rt["scheduleId"], rt["orderId"], rt.get("trainOrderId"))
            routes.setdefault(key, rt)
    stats["routes_in"] = len(routes)

    positions = {}

    def pos(stid):
        if stid not in positions:
            nm = names.get(stid)
            hit = geocoder.locate(stid, nm) if nm else None
            positions[stid] = hit
            if hit is None:
                stats["geocode_missing"].append(stid)
        return positions[stid]

    min_date = (today - timedelta(days=1)).isoformat()
    trips, stop_times, cal, route_rows, used_stops, trip_index = [], [], [], {}, set(), {}
    for key in sorted(routes, key=lambda k: (k[0], k[1], k[2] or 0)):
        rt = routes[key]
        dates = sorted(x for x in rt["operatingDates"] if x >= min_date)
        if not dates:
            drop("no_future_dates")
            continue
        rows, prev, ok = [], 0, True
        for st in sorted(rt["stations"], key=lambda s: s["orderNumber"]):
            if _is_pass_through(st, cfg):
                continue
            arr = None if st.get("arrivalTime") is None else \
                (st.get("arrivalDay") or 0) * 86400 + parse_dur(st["arrivalTime"])
            dep = None if st.get("departureTime") is None else \
                (st.get("departureDay") or 0) * 86400 + parse_dur(st["departureTime"])
            if arr is None and dep is None:
                continue
            arr = dep if arr is None else arr
            dep = arr if dep is None else dep
            if arr > dep or arr < prev:
                ok = False
                break
            prev = dep
            if pos(st["stationId"]) is None:
                continue
            rows.append((st, arr, dep))
        if not ok:
            drop("non_monotonic_times")
            continue
        if len(rows) < 2:
            drop("fewer_than_2_located_stops")
            continue

        tid = trip_id(*key)
        cc = rt.get("commercialCategorySymbol") or ""
        nm = rt.get("name") or ""
        carrier = rt.get("carrierCode") or "UNK"
        rid = "%s_%s_%s" % (slug(carrier), slug(cc), slug(nm)) if nm else "%s_%s" % (slug(carrier), slug(cc))
        short = nm or cc or carrier
        long_ = (cc + " " + nm).strip()
        if long_ == short:
            long_ = "%s %s" % (carriers.get(carrier, carrier), short)
        route_rows[rid] = (rid, carrier, short, long_, 2)
        head = names.get(rows[-1][0]["stationId"], "")
        trips.append((rid, "svc-" + tid, tid, head, rt.get("nationalNumber") or ""))
        cal.extend(("svc-" + tid, d.replace("-", ""), 1) for d in dates)
        for seq, (st, arr, dep) in enumerate(rows, 1):
            used_stops.add(st["stationId"])
            stop_times.append((tid, hms(arr), hms(dep), str(st["stationId"]), seq))
        trip_index[tid] = {"dates": [d.replace("-", "") for d in dates],
                           "stops": [str(st["stationId"]) for st, _, _ in rows]}
    stats["trips"] = len(trips)
    if not trips:
        raise ValueError("no usable trips in schedule data")

    stop_rows = []
    for stid in sorted(used_stops):
        lat, lon, src = positions[stid]
        stats["osm_positions" if src == "osm-nominatim" else "override_positions"] += 1
        desc = ("Position derived from OpenStreetMap, not published by PLK" if src == "osm-nominatim"
                else "Position set manually by feed operator")
        stop_rows.append((stid, names[stid], desc, "%.6f" % lat, "%.6f" % lon))

    used_carriers = sorted({r[1] for r in route_rows.values()})
    all_dates = sorted(d for _, d, _ in cal)
    feed_info = [("kowal-lab-maps-adapter (internal use)", AGENCY_URL, "pl", all_dates[0], all_dates[-1],
                  "%s-%s" % (schedules_version[:8], today.strftime("%Y%m%d")), "hopkuba@gmail.com")]
    files = {
        "agency.txt": _csv(["agency_id", "agency_name", "agency_url", "agency_timezone", "agency_lang"],
                           [(c, carriers.get(c, c), AGENCY_URL, "Europe/Warsaw", "pl") for c in used_carriers]),
        "stops.txt": _csv(["stop_id", "stop_name", "stop_desc", "stop_lat", "stop_lon"], stop_rows),
        "routes.txt": _csv(["route_id", "agency_id", "route_short_name", "route_long_name", "route_type"],
                           sorted(route_rows.values())),
        "trips.txt": _csv(["route_id", "service_id", "trip_id", "trip_headsign", "trip_short_name"], trips),
        "stop_times.txt": _csv(["trip_id", "arrival_time", "departure_time", "stop_id", "stop_sequence"],
                               stop_times),
        "calendar_dates.txt": _csv(["service_id", "date", "exception_type"], sorted(cal)),
        "feed_info.txt": _csv(["feed_publisher_name", "feed_publisher_url", "feed_lang", "feed_start_date",
                               "feed_end_date", "feed_version", "feed_contact_email"], feed_info),
        "attributions.txt": _csv(
            ["attribution_id", "organization_name", "is_producer", "is_authority", "attribution_url"],
            [("plk", "PKP Polskie Linie Kolejowe S.A.", 1, 1, "https://pdp-api.plk-sa.pl/"),
             ("osm", "OpenStreetMap contributors (derived stop positions, ODbL)", 1, 0,
              "https://www.openstreetmap.org/copyright")]),
        "license.txt": LICENSE_TEXT.encode("utf8"),
    }
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(files):
            z.writestr(zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0)), files[name], zipfile.ZIP_DEFLATED)
    index = {"built_for": today.isoformat(), "schedules_version": schedules_version, "trips": trip_index}
    return buf.getvalue(), index, stats


def window(today, days):
    return today.isoformat(), (today + timedelta(days=days - 1)).isoformat()


__all__ = ["build", "trip_id", "window", "date"]
