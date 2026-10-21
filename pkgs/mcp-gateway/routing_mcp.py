"""Routing MCP on a local OpenTripPlanner, plus the transit feed registry.

Street routing works with no feeds. Transit tools say so plainly until a feed is in the loaded graph.
Feed downloads are SSRF-hardened (see safe_open). Rebuilds happen on the desktop; this server only records requests.
"""
import csv
import datetime
import hashlib
import http.client
import io
import ipaddress
import json
import os
import re
import socket
import ssl
import threading
import time
import urllib.parse
import urllib.request
import zipfile
from zoneinfo import ZoneInfo

import yaml

from stdio_mcp import obj, serve

OTP = os.environ.get("OTP_URL", "http://mcp-otp:8080")
NOM = os.environ.get("NOMINATIM_URL", "http://mcp-nominatim:8080")
STATE = os.environ.get("STATE_DIR", "/state")
MANIFEST = os.environ.get("GRAPH_MANIFEST", "/maps/graph/manifest.json")
FEEDS = os.path.join(STATE, "feeds.yaml")
LOCAL_FEEDS = os.path.join(STATE, "feeds-local")
REBUILD = os.path.join(STATE, "rebuild-request.json")
UA = f"kowal-lab-maps/0.1 (personal use; contact {os.environ.get('FEED_CONTACT', 'unset')})"
TZ = ZoneInfo("Europe/Warsaw")
PER_MINUTE = int(os.environ.get("ROUTING_PER_MINUTE", "30"))
MAX_STEPS = 40
MAX_CHARS = 30000
NO_FEEDS = "no transit feeds loaded; add one via feeds.yaml or feed_add"
ATTRIBUTION = "© OpenStreetMap contributors (ODbL)"
calls, lock = [], threading.Lock()

HEADER = """# Transit feed registry: the source of truth for the graph build on the desktop.
# Fields per feed (all in one example):
#
# feeds:
#   - id: kmk-bus                      # short, lowercase; becomes the OTP feed id prefix
#     name: KMK Krakow buses
#     static: https://example.org/gtfs/bus.zip      # or file:name.zip for a file in the feeds-local folder
#     update_check_hours: 24
#     realtime:
#       trip_updates: https://example.org/rt/trip_updates.pb
#       vehicle_positions: https://example.org/rt/vehicle_positions.pb
#       service_alerts: https://example.org/rt/alerts.pb
#     poll_seconds: 30                 # never below 30 for public feeds
#     auth: null                       # NAME of a docker secret, never the secret itself
#     allow_ports: []                  # explicit host:port entries for providers on non-standard ports
#     license: "state the licence, or 'unclear'"
#     attribution: "who to credit"
#     enabled: true
#     internal_adapter: false          # only settable by editing this file by hand; the tools can never set it
#
"""


def budget():
    with lock:
        now = time.time()
        calls[:] = [t for t in calls if t > now - 60]
        if len(calls) >= PER_MINUTE:
            raise RuntimeError(f"rate limit of {PER_MINUTE} routing calls per minute reached")
        calls.append(now)


# ---------------------------------------------------------------- registry
def load_feeds():
    try:
        with open(FEEDS) as f:
            data = yaml.safe_load(f) or {}
    except FileNotFoundError:
        return []
    return data.get("feeds") or []


def save_feeds(feeds):
    os.makedirs(STATE, exist_ok=True)
    tmp = FEEDS + ".tmp"
    with open(tmp, "w") as f:
        f.write(HEADER)
        yaml.safe_dump({"feeds": feeds}, f, sort_keys=False, allow_unicode=True)
    os.replace(tmp, FEEDS)


def manifest():
    try:
        with open(MANIFEST) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def feeds_loaded():
    return manifest().get("feeds") or []


def rebuild_pending():
    try:
        with open(REBUILD) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def request_rebuild(reason):
    os.makedirs(STATE, exist_ok=True)
    with open(REBUILD + ".tmp", "w") as f:
        json.dump({"requested_at": datetime.datetime.now(TZ).isoformat(timespec="seconds"), "reason": reason}, f)
    os.replace(REBUILD + ".tmp", REBUILD)


# ---------------------------------------------------------------- OTP and places
def gql(query, variables=None):
    budget()
    req = urllib.request.Request(f"{OTP}/otp/gtfs/v1", method="POST", data=json.dumps({"query": query, "variables": variables or {}}).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        res = json.load(r)
    if res.get("errors"):
        raise RuntimeError("routing engine error: " + "; ".join(e.get("message", "?")[:120] for e in res["errors"][:2]))
    return res["data"]


COORD = re.compile(r"^\s*(-?\d{1,3}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*$")


def resolve(place):
    """a place name goes to the local Nominatim; the resolved coordinates are always echoed back."""
    m = COORD.match(str(place))
    if m:
        return {"query": place, "name": None, "lat": float(m[1]), "lon": float(m[2])}
    budget()
    url = f"{NOM}/search?" + urllib.parse.urlencode({"q": place, "format": "jsonv2", "limit": 1, "accept-language": "pl,en", "countrycodes": "pl,cz,sk"})
    with urllib.request.urlopen(url, timeout=15) as r:
        hits = json.load(r)
    if not hits:
        raise RuntimeError(f"could not find a place for '{place}', try coordinates as 'lat,lon'")
    return {"query": place, "name": hits[0]["display_name"][:100], "lat": float(hits[0]["lat"]), "lon": float(hits[0]["lon"])}


def need_feeds():
    if not feeds_loaded():
        raise RuntimeError(NO_FEEDS)


def hhmm(sec):
    return f"{int(sec) // 3600 % 24:02d}:{int(sec) % 3600 // 60:02d}"


def parse_dt(s):
    if not s:
        return None
    d = datetime.datetime.fromisoformat(s)
    return d if d.tzinfo else d.replace(tzinfo=TZ)


def coord_input(p):
    return f'{{location:{{coordinate:{{latitude:{p["lat"]},longitude:{p["lon"]}}}}}}}'


def compact_steps(steps):
    """merge consecutive pieces of the same street, then keep the longest MAX_STEPS in order, so long routes stay readable."""
    merged = []
    for s in steps:
        if merged and merged[-1]["street"] == s["streetName"]:
            merged[-1]["dist"] += s["distance"]
        else:
            merged.append({"dir": s["relativeDirection"].lower(), "street": s["streetName"], "dist": s["distance"]})
    if len(merged) > MAX_STEPS:
        keep = {id(m) for m in sorted(merged, key=lambda m: -m["dist"])[:MAX_STEPS]}
        merged = [m for m in merged if id(m) in keep]
    return [f'{m["dir"]} {m["street"]} {round(m["dist"])} m' for m in merged]


def leg_out(l):
    out = {"mode": l["mode"], "from": (l["from"] or {}).get("name"), "to": (l["to"] or {}).get("name"),
           "start": l["start"]["scheduledTime"][11:16] if l.get("start") else None,
           "end": l["end"]["scheduledTime"][11:16] if l.get("end") else None,
           "distance_m": round(l["distance"]), "duration_s": round(l["duration"])}
    if l.get("route"):
        out["line"] = l["route"].get("shortName") or l["route"].get("longName")
        out["headsign"] = l.get("headsign")
        out["agency"] = (l["route"].get("agency") or {}).get("name")
    if l.get("realTime"):
        out["realtime"] = True
        delay = ((l["start"].get("estimated") or {}).get("delay"))
        if delay:
            out["delay"] = delay
    if l.get("steps"):
        out["steps"] = compact_steps(l["steps"])
    return out


LEG = """legs { mode duration distance realTime headsign
  from { name } to { name }
  start { scheduledTime estimated { delay } } end { scheduledTime }
  route { shortName longName agency { name } }
  steps { relativeDirection streetName distance } }"""


def plan(frm, to, direct=None, depart_at=None, arrive_by=None, n=1, transit=False):
    a, b = resolve(frm), resolve(to)
    when = ""
    if arrive_by:
        when = f'dateTime:{{latestArrival:"{parse_dt(arrive_by).isoformat()}"}}'
    elif depart_at:
        when = f'dateTime:{{earliestDeparture:"{parse_dt(depart_at).isoformat()}"}}'
    modes = f"modes:{{direct:[{direct}]}}" if direct else ""
    q = f"{{ planConnection(origin:{coord_input(a)} destination:{coord_input(b)} {when} {modes} first:{max(1, min(int(n), 3))}) {{ edges {{ node {{ start end duration numberOfTransfers {LEG} }} }} }} }}"
    edges = gql(q)["planConnection"]["edges"]
    its = [{"start": e["node"]["start"][11:16], "end": e["node"]["end"][11:16], "duration_min": round(e["node"]["duration"] / 60),
            "transfers": e["node"]["numberOfTransfers"], "distance_m": round(sum(l["distance"] for l in e["node"]["legs"])),
            "legs": [leg_out(l) for l in e["node"]["legs"]]} for e in edges]
    return {"from": a, "to": b, "itineraries": its, "attribution": ATTRIBUTION}


def cap(out):
    """always valid JSON: shrink by dropping steps, then alternatives, instead of cutting the text."""
    s = json.dumps(out, ensure_ascii=False)
    if len(s) <= MAX_CHARS or not isinstance(out, dict):
        return s if len(s) <= MAX_CHARS else s[:MAX_CHARS]
    for it in out.get("itineraries", []):
        for leg in it.get("legs", []):
            leg.pop("steps", None)
    out["truncated"] = "steps dropped to fit the output limit"
    s = json.dumps(out, ensure_ascii=False)
    while len(s) > MAX_CHARS and len(out.get("itineraries", [])) > 1:
        out["itineraries"].pop()
        s = json.dumps(out, ensure_ascii=False)
    return s


# ---------------------------------------------------------------- tools: routing
def t_route(a):
    mode = {"walk": "WALK", "bike": "BICYCLE", "car": "CAR"}.get(a.get("mode", "walk"))
    if not mode:
        raise RuntimeError("mode must be walk, bike or car")
    return cap(plan(a["from"], a["to"], direct=mode, depart_at=a.get("depart_at"), n=a.get("alternatives", 1)))


def t_transit_plan(a):
    need_feeds()
    return cap(plan(a["from"], a["to"], depart_at=a.get("depart_at"), arrive_by=a.get("arrive_by"), n=a.get("alternatives", 2), transit=True))


def t_stops_nearby(a):
    need_feeds()
    p = resolve(a["place"])
    r = min(float(a.get("radius_m", 400)), 1500)
    d = gql(f'{{ nearest(latitude:{p["lat"]}, longitude:{p["lon"]}, maxDistance:{int(r)}, filterByPlaceTypes:[STOP], first:15) {{ edges {{ node {{ distance place {{ ... on Stop {{ gtfsId name code lat lon }} }} }} }} }} }}')
    return cap({"place": p, "stops": [{"id": e["node"]["place"]["gtfsId"], "name": e["node"]["place"]["name"], "code": e["node"]["place"].get("code"),
                                       "distance_m": round(e["node"]["distance"])} for e in d["nearest"]["edges"] if e["node"]["place"]]})


def t_stop_departures(a):
    need_feeds()
    n = max(1, min(int(a.get("count", 8)), 20))
    d = gql(f'{{ stop(id:"{a["stop_id"]}") {{ name stoptimesWithoutPatterns(numberOfDepartures:{n}) {{ scheduledDeparture realtimeDeparture departureDelay realtime headsign trip {{ route {{ shortName }} }} }} }} }}')
    s = d["stop"]
    if not s:
        raise RuntimeError("unknown stop_id, use stops_nearby to find ids")
    return cap({"stop": s["name"], "departures": [{"line": x["trip"]["route"]["shortName"], "to": x["headsign"], "time": hhmm(x["realtimeDeparture"]),
                                                   "scheduled": hhmm(x["scheduledDeparture"]), "delay_s": x["departureDelay"], "realtime": x["realtime"]}
                                                  for x in s["stoptimesWithoutPatterns"]]})


def t_vehicle_positions(a):
    need_feeds()
    d = gql(f'{{ route(id:"{a["route_id"]}") {{ shortName patterns {{ vehiclePositions {{ label lat lon heading speed lastUpdated stopRelationship {{ status stop {{ name }} }} }} }} }} }}')
    r = d["route"]
    if not r:
        raise RuntimeError("unknown route_id")
    vs = [v for p in r["patterns"] for v in (p["vehiclePositions"] or [])]
    return cap({"line": r["shortName"], "vehicles": vs[:50]})


def t_service_alerts(a):
    need_feeds()
    d = gql(f'{{ route(id:"{a["route_id"]}") {{ shortName alerts {{ alertHeaderText alertDescriptionText effectiveStartDate effectiveEndDate }} }} }}')
    r = d["route"]
    if not r:
        raise RuntimeError("unknown route_id")
    return cap({"line": r["shortName"], "alerts": r["alerts"]})


def t_trip_detail(a):
    need_feeds()
    d = gql(f'{{ trip(id:"{a["trip_id"]}") {{ tripHeadsign route {{ shortName longName }} stoptimes {{ stop {{ name }} scheduledDeparture realtimeDeparture realtime }} }} }}')
    t = d["trip"]
    if not t:
        raise RuntimeError("unknown trip_id")
    return cap({"line": t["route"]["shortName"], "to": t["tripHeadsign"],
                "stops": [{"stop": s["stop"]["name"], "time": hhmm(s["realtimeDeparture"]), "scheduled": hhmm(s["scheduledDeparture"]), "realtime": s["realtime"]} for s in t["stoptimes"]]})


def t_info(_a):
    m = manifest()
    healthy = True
    try:
        urllib.request.urlopen(f"{OTP}/otp", timeout=5).read()
    except Exception:
        healthy = False
    feeds = load_feeds()
    return {"engine": "OpenTripPlanner " + str(m.get("otp_version", "?")), "engine_reachable": healthy, "graph_built_at": m.get("built_at"),
            "osm_data_timestamp": m.get("osm_data_timestamp"), "graph_feeds": m.get("feeds") or [],
            "registry": [{"id": f.get("id"), "enabled": f.get("enabled", True)} for f in feeds],
            "rebuild_pending": rebuild_pending(), "transit": "available" if m.get("feeds") else NO_FEEDS, "attribution": ATTRIBUTION}


# ---------------------------------------------------------------- safe downloads
def check_url(url, extra_ports=()):
    p = urllib.parse.urlsplit(url)
    if p.scheme not in ("http", "https") or not p.hostname or p.username or p.password:
        raise RuntimeError("feed URLs must be plain http(s) without credentials")
    port = p.port or (443 if p.scheme == "https" else 80)
    if port not in (80, 443) and f"{p.hostname}:{port}" not in extra_ports:
        raise RuntimeError(f"port {port} is not allowed; add '{p.hostname}:{port}' to allow_ports on the feed to permit it")
    ips = []
    for info in socket.getaddrinfo(p.hostname, port, type=socket.SOCK_STREAM):
        ip = ipaddress.ip_address(info[4][0].split("%")[0])
        if not ip.is_global:  # private, loopback, link-local (incl. cloud metadata), CGNAT, docker ranges, reserved
            raise RuntimeError(f"{p.hostname} resolves to a non-public address, refused")
        ips.append(str(ip))
    return p, port, ips[0]


def safe_open(url, max_bytes=80_000_000, timeout=60, extra_ports=()):
    deadline = time.time() + timeout
    for _ in range(4):
        p, port, ip = check_url(url, extra_ports)
        base = http.client.HTTPSConnection if p.scheme == "https" else http.client.HTTPConnection

        class Pinned(base):  # connect to the address that was just checked, so DNS cannot change between check and use
            def connect(self):
                self.sock = socket.create_connection((ip, port), timeout=20)
                if p.scheme == "https":
                    self.sock = ssl.create_default_context().wrap_socket(self.sock, server_hostname=p.hostname)

        conn = Pinned(p.hostname, port, timeout=20)
        conn.request("GET", (p.path or "/") + ("?" + p.query if p.query else ""), headers={"Host": p.netloc, "User-Agent": UA, "Accept-Encoding": "identity"})
        r = conn.getresponse()
        if 300 <= r.status < 400 and r.getheader("Location"):
            url = urllib.parse.urljoin(url, r.getheader("Location"))
            conn.close()
            continue
        if r.status != 200:
            conn.close()
            raise RuntimeError(f"download failed with HTTP {r.status}")
        buf = io.BytesIO()
        while True:
            chunk = r.read(65536)
            if not chunk:
                break
            buf.write(chunk)
            if buf.tell() > max_bytes or time.time() > deadline:
                conn.close()
                raise RuntimeError("download exceeded the size or time limit")
        conn.close()
        return buf.getvalue()
    raise RuntimeError("too many redirects")


def local_file(ref):
    name = ref[5:]
    if not re.match(r"^[\w.-]{1,80}\.zip$", name):
        raise RuntimeError("file: references must be a plain zip file name")
    with open(os.path.join(LOCAL_FEEDS, name), "rb") as f:
        return f.read(80_000_001)


def read_zip(data):
    """read specific members into memory with size and ratio caps; nothing is ever extracted to disk."""
    zf = zipfile.ZipFile(io.BytesIO(data))
    infos = zf.infolist()
    if len(infos) > 100:
        raise RuntimeError("zip has too many members")
    total = 0
    for i in infos:
        n = i.filename
        if n.startswith("/") or ".." in n.split("/") or "\\" in n:
            raise RuntimeError("zip contains an unsafe path")
        total += i.file_size
        if i.compress_size and i.file_size / i.compress_size > 200:
            raise RuntimeError("zip member compression ratio is implausible")
    if total > 800_000_000:
        raise RuntimeError("zip expands to too much data")
    return zf


def rows(zf, name, limit=None):
    if name not in zf.namelist():
        return None
    with zf.open(name) as f:
        r = csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig", newline=""))
        return [x for _, x in zip(range(limit or 10**9), r)] if limit else list(r)


def validate_zip(data):
    errors, warnings = [], []
    zf = read_zip(data)
    names = set(zf.namelist())
    for req in ("agency.txt", "stops.txt", "routes.txt", "trips.txt", "stop_times.txt"):
        if req not in names:
            errors.append(f"missing {req}")
    if "calendar.txt" not in names and "calendar_dates.txt" not in names:
        errors.append("missing calendar.txt and calendar_dates.txt")
    if errors:
        return {"errors": errors, "warnings": warnings}
    agency = rows(zf, "agency.txt")
    stops = rows(zf, "stops.txt")
    routes = rows(zf, "routes.txt")
    trips = rows(zf, "trips.txt")
    bad = sum(1 for s in stops if s.get("stop_lat", "") == "" or s.get("stop_lon", "") == "")
    if bad:
        warnings.append(f"{bad} stops without coordinates")
    tzs = {a.get("agency_timezone") for a in agency}
    if tzs != {"Europe/Warsaw"}:
        warnings.append(f"agency timezones are {sorted(t for t in tzs if t)}, expected Europe/Warsaw")
    dates = []
    for f, cols in (("calendar.txt", ("start_date", "end_date")), ("calendar_dates.txt", ("date",))):
        for r in rows(zf, f) or []:
            dates += [r[c] for c in cols if r.get(c)]
    if dates:
        lo, hi = min(dates), max(dates)
        today = datetime.datetime.now(TZ).strftime("%Y%m%d")
        if hi < today:
            errors.append(f"service ended on {hi}")
        elif hi < (datetime.datetime.now(TZ) + datetime.timedelta(days=14)).strftime("%Y%m%d"):
            warnings.append(f"service ends within 14 days ({hi})")
    else:
        errors.append("no service dates found")
    xs = rows(zf, "stop_times.txt", 1)
    if not xs:
        errors.append("stop_times.txt is empty")
    return {"errors": errors, "warnings": warnings, "agency": [a.get("agency_name") for a in agency][:5],
            "service_dates": [min(dates), max(dates)] if dates else None, "stops": len(stops), "routes": len(routes), "trips": len(trips),
            "note": "basic checks; the full MobilityData validator runs on the desktop during the graph build"}


def fetch_static(ref, extra_ports=()):
    return local_file(ref) if ref.startswith("file:") else safe_open(ref, extra_ports=extra_ports)


# ---------------------------------------------------------------- tools: registry
def t_feed_list(_a):
    return [{k: v for k, v in f.items() if k != "auth"} | {"auth": "secret:" + f["auth"] if f.get("auth") else None} for f in load_feeds()] or "registry is empty"


def t_feed_validate(a):
    url = a.get("url", "")
    data = fetch_static(url, tuple(a.get("allow_ports") or []))
    res = validate_zip(data)
    return {**res, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "changed_nothing": True}


def t_feed_add(a):
    fid = a.get("id", "")
    if not re.match(r"^[a-z0-9][a-z0-9-]{1,30}$", fid):
        raise RuntimeError("id must be 2 to 31 characters of a-z, 0-9 and dashes")
    if any(f.get("id") == fid for f in load_feeds()):
        raise RuntimeError("a feed with this id exists, remove it first")
    ports = list(a.get("allow_ports") or [])
    rt = {k: a[k] for k in ("trip_updates", "vehicle_positions", "service_alerts") if a.get(k)}
    for u in rt.values():
        check_url(u, tuple(ports))
    res = validate_zip(fetch_static(a.get("static", ""), tuple(ports)))
    findings = {**res, "rt_urls_checked": list(rt)}
    if res["errors"] or a.get("confirm") is not True:
        return {"added": False, "findings": findings,
                "next": "fix the errors" if res["errors"] else "review the findings, then call again with confirm=true"}
    entry = {"id": fid, "name": a.get("name", fid), "static": a["static"], "update_check_hours": 24, "realtime": rt or None,
             "poll_seconds": max(int(a.get("poll_seconds", 30)), 30), "auth": a.get("auth"), "allow_ports": ports,
             "license": a.get("license", "unclear"), "attribution": a.get("attribution", ""), "enabled": True, "internal_adapter": False}
    save_feeds(load_feeds() + [entry])
    request_rebuild(f"feed {fid} added")
    return {"added": True, "findings": findings, "note": "recorded; the graph is rebuilt on the desktop, see routing_data_info"}


def t_feed_remove(a):
    feeds = load_feeds()
    if not any(f.get("id") == a.get("id") for f in feeds):
        raise RuntimeError("unknown feed id")
    if a.get("confirm") is not True:
        return {"removed": False, "next": "call again with confirm=true"}
    save_feeds([f for f in feeds if f.get("id") != a["id"]])
    request_rebuild(f"feed {a['id']} removed")
    return {"removed": True}


def t_feed_enabled(a):
    feeds = load_feeds()
    hit = [f for f in feeds if f.get("id") == a.get("id")]
    if not hit:
        raise RuntimeError("unknown feed id")
    hit[0]["enabled"] = bool(a.get("enabled"))
    save_feeds(feeds)
    request_rebuild(f"feed {a['id']} enabled={hit[0]['enabled']}")
    return {"id": a["id"], "enabled": hit[0]["enabled"]}


def t_rebuild(a):
    request_rebuild(str(a.get("reason", "manual request"))[:120])
    return {"recorded": True, "note": "the desktop picks this up on its next run of build-graph.sh"}


PLACE = {"type": "string", "description": "a place name or 'lat,lon'"}
WHEN = {"depart_at": {"type": "string", "description": "local ISO time, e.g. 2026-10-21T08:00"}}
R = {"ro": True, "class": "read"}
W = {"class": "write"}
TOOLS = {
    "route": dict(desc="Street route between two places by walk, bike or car. Echoes the resolved coordinates.", **R,
                  schema=obj({"from": PLACE, "to": PLACE, "mode": {"type": "string", "enum": ["walk", "bike", "car"]}, "alternatives": {"type": "integer"}, **WHEN}, ["from", "to"]), fn=t_route),
    "transit_plan": dict(desc="Public transport itinerary between two places. " + NO_FEEDS + " when the graph has no feeds.", **R,
                         schema=obj({"from": PLACE, "to": PLACE, **WHEN, "arrive_by": {"type": "string"}, "alternatives": {"type": "integer"}}, ["from", "to"]), fn=t_transit_plan),
    "stops_nearby": dict(desc="Transit stops near a place.", **R, schema=obj({"place": PLACE, "radius_m": {"type": "number"}}, ["place"]), fn=t_stops_nearby),
    "stop_departures": dict(desc="Next departures at a stop, realtime-aware.", **R, schema=obj({"stop_id": {"type": "string"}, "count": {"type": "integer"}}, ["stop_id"]), fn=t_stop_departures),
    "vehicle_positions": dict(desc="Live vehicle positions for a route.", **R, schema=obj({"route_id": {"type": "string"}}, ["route_id"]), fn=t_vehicle_positions),
    "service_alerts": dict(desc="Service alerts for a route.", **R, schema=obj({"route_id": {"type": "string"}}, ["route_id"]), fn=t_service_alerts),
    "trip_detail": dict(desc="Stops and times of one trip.", **R, schema=obj({"trip_id": {"type": "string"}}, ["trip_id"]), fn=t_trip_detail),
    "routing_data_info": dict(desc="Graph build time, engine version, OSM date, loaded feeds, rebuild status.", **R, schema=obj(), fn=t_info),
    "feed_list": dict(desc="The transit feed registry (secrets are never shown).", **R, schema=obj(), fn=t_feed_list),
    "feed_validate": dict(desc="Download a candidate GTFS zip safely and report its contents. Changes nothing.", **R,
                          schema=obj({"url": {"type": "string"}, "allow_ports": {"type": "array", "items": {"type": "string"}}}, ["url"]), fn=t_feed_validate),
    "feed_add": dict(desc="Add a feed to the registry after validating it. Needs confirm=true after you have seen the findings.", **W,
                     schema=obj({"id": {"type": "string"}, "name": {"type": "string"}, "static": {"type": "string"}, "trip_updates": {"type": "string"},
                                 "vehicle_positions": {"type": "string"}, "service_alerts": {"type": "string"}, "poll_seconds": {"type": "integer"},
                                 "auth": {"type": "string", "description": "NAME of a docker secret"}, "license": {"type": "string"}, "attribution": {"type": "string"},
                                 "allow_ports": {"type": "array", "items": {"type": "string"}}, "confirm": {"type": "boolean"}}, ["id", "static"]), fn=t_feed_add),
    "feed_remove": dict(desc="Remove a feed from the registry.", **W, schema=obj({"id": {"type": "string"}, "confirm": {"type": "boolean"}}, ["id"]), fn=t_feed_remove),
    "feed_set_enabled": dict(desc="Enable or disable a feed.", **W, schema=obj({"id": {"type": "string"}, "enabled": {"type": "boolean"}}, ["id", "enabled"]), fn=t_feed_enabled),
    "graph_rebuild_request": dict(desc="Record a request to rebuild the graph on the desktop.", **W, schema=obj({"reason": {"type": "string"}}), fn=t_rebuild),
}


if __name__ == "__main__":
    serve("routing", TOOLS)
