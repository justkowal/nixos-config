"""Rewrite ZTM GZM realtime trip ids ('1_6045354') to the mkuran.pl static ids ('11607:1_6045354').

The static feed prefixes every service id with the publication number of its service day. The realtime feed carries no date, so the
prefix is looked up from calendar_dates for today and yesterday (night trips run past midnight) and the result must exist in trips.txt.
"""
import csv
import io
import zipfile
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

WAW = ZoneInfo("Europe/Warsaw")


def load_ids(zip_path):
    """-> (services, trips): services[YYYYMMDD] = set of 'ver:svc' ids active that day, trips = set of trip ids."""
    services, trips = {}, set()
    with zipfile.ZipFile(zip_path) as z:
        with z.open("calendar_dates.txt") as f:
            for r in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig", newline="")):
                if r["exception_type"] == "1":
                    services.setdefault(r["date"], set()).add(r["service_id"])
        with z.open("trips.txt") as f:
            for r in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig", newline="")):
                trips.add(r["trip_id"])
    return services, trips


def days(now):
    d = datetime.fromtimestamp(now, WAW)
    return [d.strftime("%Y%m%d"), (d - timedelta(days=1)).strftime("%Y%m%d")]


def translate(rt_id, services, trips, now):
    """-> (static_trip_id, service_date) or None when the id cannot be placed on a known service day."""
    svc = rt_id.split("_", 1)[0]
    for day in days(now):
        for full in services.get(day, ()):
            if full.split(":", 1)[-1] == svc and f"{full.split(':', 1)[0]}:{rt_id}" in trips:
                return f"{full.split(':', 1)[0]}:{rt_id}", day
    return None
