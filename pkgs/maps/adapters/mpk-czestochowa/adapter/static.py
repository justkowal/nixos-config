"""Static feed: mirror the operator's official GTFS from its public share and add metadata.

The publisher's data is passed through untouched. Only these changes are made:
feed_version and contact url added to feed_info.txt, attributions.txt and LICENSE.txt
added, the broken shape_dist_traveled column dropped, [Content_Types].xml and the
header-only transfers.txt removed.
"""
import csv
import datetime as dt
import io
import json
import logging
import os
import re
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
from zoneinfo import ZoneInfo

from guard import fetch

log = logging.getLogger("static")
TZ = ZoneInfo("Europe/Warsaw")
DAV = "{DAV:}"
FOLDER = re.compile(r"^\d{4}\.\d{2}\.\d{2}$")
DROP = {"[Content_Types].xml", "transfers.txt"}

ATTRIBUTIONS = (
    "attribution_id,organization_name,is_producer,is_operator,is_authority,attribution_url\n"
    "producer,Urzad Miasta Czestochowy,1,0,1,http://czestochowa.pl\n"
    "operator,Miejskie Przedsiebiorstwo Komunikacyjne w Czestochowie S.A.,0,1,0,http://mpk.czest.pl\n"
)
LICENSE = """Source: official GTFS published by Urzad Miasta Czestochowy / MPK Czestochowa
on the public share linked from https://mpk.czest.pl (folder "Dane rozkladowe").
The publisher states no licence or terms of use for this file.
This copy is produced for private, non-commercial use only and is kept internal.
It must not be published or redistributed.
Changes: feed_info.txt (feed_version, feed_contact_url added), shapes.txt
(invalid shape_dist_traveled column removed), attributions.txt and LICENSE.txt
added. All schedule data is otherwise exactly as published.
"""


def parse_listing(xml_bytes):
    out = []
    for r in ET.fromstring(xml_bytes).iter(DAV + "response"):
        href = urllib.parse.unquote(r.findtext(DAV + "href"))
        is_dir = r.find(f".//{DAV}collection") is not None
        etag = (r.findtext(f".//{DAV}getetag") or "").strip('"')
        out.append({"name": href.rstrip("/").rsplit("/", 1)[-1], "dir": is_dir, "etag": etag})
    return out[1:]


def pick_folder(entries, today):
    """Newest dated folder that is not in the future."""
    names = [e["name"] for e in entries if e["dir"] and FOLDER.match(e["name"])
             and dt.datetime.strptime(e["name"], "%Y.%m.%d").date() <= today]
    return max(names) if names else None


def _drop_column(data, col):
    """The published shape_dist_traveled repeats values across distinct points (invalid), so it is removed."""
    r = csv.reader(io.StringIO(data.decode("utf-8-sig")))
    head = next(r)
    if col not in head:
        return data
    i = head.index(col)
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(head[:i] + head[i + 1:])
    for row in r:
        w.writerow(row[:i] + row[i + 1:])
    return buf.getvalue().encode()


def patch_zip(src_bytes, version, out_path):
    zin = zipfile.ZipFile(io.BytesIO(src_bytes))
    tmp = out_path + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for name in sorted(zin.namelist()):
            if name in DROP:
                continue
            data = zin.read(name)
            if name == "feed_info.txt":
                rows = list(csv.reader(io.StringIO(data.decode("utf-8-sig"))))
                rows[0] += ["feed_version", "feed_contact_url"]
                rows[1] += [version, "http://mpk.czest.pl"]
                buf = io.StringIO()
                csv.writer(buf, lineterminator="\n").writerows(rows)
                data = buf.getvalue().encode()
            elif name == "shapes.txt":
                data = _drop_column(data, "shape_dist_traveled")
            zout.writestr(zipfile.ZipInfo(name, (2000, 1, 1, 0, 0, 0)), data, zipfile.ZIP_DEFLATED)
        for name, text in (("attributions.txt", ATTRIBUTIONS), ("LICENSE.txt", LICENSE)):
            zout.writestr(zipfile.ZipInfo(name, (2000, 1, 1, 0, 0, 0)), text, zipfile.ZIP_DEFLATED)
    os.replace(tmp, out_path)


def sync(cfg, guard, data_dir, today=None):
    """Refresh the static zip if the publisher has something newer. Returns the version or None."""
    today = today or dt.datetime.now(TZ).date()
    src = cfg["source"]
    base = f"{src['share_base']}/{urllib.parse.quote(src['share_dir'])}"
    auth = f"{src['share_token']}:"
    ua = src["user_agent"]
    _, _, body = fetch(guard, base + "/", ua, "PROPFIND", {"Depth": "1"}, auth)
    folder = pick_folder(parse_listing(body), today)
    if not folder:
        raise OSError("no dated folder in share")
    _, _, body = fetch(guard, f"{base}/{folder}/", ua, "PROPFIND", {"Depth": "1"}, auth)
    zname = f"GTFS_{folder}.zip"
    entry = next((e for e in parse_listing(body) if e["name"] == zname), None)
    if not entry:
        raise OSError(f"{zname} missing in {folder}")
    meta_path = os.path.join(data_dir, "static-meta.json")
    try:
        meta = json.load(open(meta_path))
    except (OSError, ValueError):
        meta = {}
    out = os.path.join(data_dir, "gtfs.zip")
    if meta.get("etag") == entry["etag"] and meta.get("folder") == folder and os.path.exists(out):
        log.info("static unchanged (%s)", folder)
        return None
    _, _, data = fetch(guard, f"{base}/{folder}/{urllib.parse.quote(zname)}", ua, "GET",
                       basic_auth=auth, max_bytes=cfg["static"]["max_bytes"])
    zipfile.ZipFile(io.BytesIO(data)).testzip()
    patch_zip(data, folder, out)
    with open(meta_path, "w") as f:
        json.dump({"etag": entry["etag"], "folder": folder, "fetched": dt.datetime.now(TZ).isoformat()}, f)
    log.info("static updated to %s", folder)
    return folder


def _csv(z, name):
    with z.open(name) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, "utf-8-sig", newline=""))


def secs(hms):
    h, m, s = hms.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


class GtfsIndex:
    """In-memory view of the static zip used to match realtime data to trips."""

    def __init__(self, path):
        z = zipfile.ZipFile(path)
        self.trips = {r["trip_id"]: r for r in _csv(z, "trips.txt")}
        self.times = {}
        for r in _csv(z, "stop_times.txt"):
            self.times.setdefault(r["trip_id"], []).append(
                (int(r["stop_sequence"]), r["stop_id"], secs(r["arrival_time"]), secs(r["departure_time"])))
        for v in self.times.values():
            v.sort()
        self.cal = {r["service_id"]: r for r in _csv(z, "calendar.txt")} if "calendar.txt" in z.namelist() else {}
        self.exc = {}
        if "calendar_dates.txt" in z.namelist():
            for r in _csv(z, "calendar_dates.txt"):
                self.exc[(r["service_id"], r["date"])] = r["exception_type"]
        self.feed_end = next(_csv(z, "feed_info.txt"), {}).get("feed_end_date")
        self.version = next(_csv(z, "feed_info.txt"), {}).get("feed_version")
        self._wcache = {}

    def service_active(self, service_id, d):
        key = (service_id, d.strftime("%Y%m%d"))
        if key in self.exc:
            return self.exc[key] == "1"
        c = self.cal.get(service_id)
        if not c:
            return False
        ds = d.strftime("%Y%m%d")
        day = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")[d.weekday()]
        return c["start_date"] <= ds <= c["end_date"] and c[day] == "1"

    def in_service(self, now_epoch, margin_s=1800):
        """True if any trip of yesterday's or today's service date runs within margin of now."""
        today = dt.datetime.fromtimestamp(now_epoch, TZ).date()
        out = []
        for d in (today - dt.timedelta(days=1), today):
            out += self._windows_for(d)
        return any(a - margin_s <= now_epoch <= b + margin_s for a, b in out)

    def _windows_for(self, d):
        cache = self._wcache
        if d not in cache:
            if len(cache) > 3:
                cache.clear()
            noon = dt.datetime.combine(d, dt.time(12), TZ)
            base = (noon - dt.timedelta(hours=12)).timestamp()
            iv = [(base + st[0][3], base + st[-1][2]) for tid, t in self.trips.items()
                  if (st := self.times.get(tid)) and self.service_active(t["service_id"], d)]
            iv.sort()
            merged = []
            for a, b in iv:
                if merged and a <= merged[-1][1]:
                    merged[-1][1] = max(merged[-1][1], b)
                else:
                    merged.append([a, b])
            cache[d] = merged
        return cache[d]
