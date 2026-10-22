"""Personal navigation web app: static PWA plus a small read-only JSON API over the local Nominatim and OpenTripPlanner.

Auth is one passphrase (NAV_SECRET) exchanged for a signed, HttpOnly cookie. The API never writes anything and takes no free-form GraphQL.
"""
import collections
import datetime
import hashlib
import hmac
import json
import math
import mimetypes
import os
import re
import sqlite3
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from zoneinfo import ZoneInfo

import places

OTP = os.environ.get("OTP_URL", "http://mcp-otp:8080")
DB = os.environ.get("NAV_DB", "")
NOM = os.environ.get("NOMINATIM_URL", "http://mcp-nominatim:8080")
STATIC = os.environ.get("NAV_STATIC", os.path.join(os.path.dirname(os.path.abspath(__file__)), "static"))
MANIFEST = os.environ.get("GRAPH_MANIFEST", "/maps/graph/manifest.json")
SECRET = os.environ.get("NAV_SECRET", "")
TZ = ZoneInfo("Europe/Warsaw")
SESSION_DAYS = 90
PER_MINUTE = int(os.environ.get("NAV_PER_MINUTE", "90"))
FAIL_LIMIT, FAIL_WINDOW = 5, 900
UA = f"kowal-lab-nav/0.1 (personal use; contact {os.environ.get('FEED_CONTACT', 'unset')})"

TRANSIT = {"rail": "RAIL", "bus": "BUS", "tram": "TRAM"}
DIRECT = {"walk": "WALK", "bike": "BICYCLE", "car": "CAR"}
CSP = ("default-src 'self'; img-src 'self' data: blob: https://tiles.openfreemap.org; connect-src 'self' https://tiles.openfreemap.org; "
       "style-src 'self' 'unsafe-inline'; script-src 'self'; worker-src 'self' blob:; font-src 'self' data:; manifest-src 'self'; "
       "frame-ancestors 'none'; base-uri 'none'; form-action 'self'")

_lock = threading.Lock()
_fails = {}
_hits = {}


# ---------------------------------------------------------------- session
def _key():
    return hashlib.sha256(b"nav-cookie|" + SECRET.encode()).digest()


def make_cookie(device="web", days=SESSION_DAYS):
    exp = str(int(time.time()) + days * 86400)
    body = f"{exp}.{device}"
    return f"{body}.{hmac.new(_key(), body.encode(), hashlib.sha256).hexdigest()}"


def session_device(value):
    """-> device name for a valid signed token, else None."""
    try:
        exp, device, sig = value.split(".", 2)
        body = f"{exp}.{device}"
        ok = int(exp) > time.time() and hmac.compare_digest(sig, hmac.new(_key(), body.encode(), hashlib.sha256).hexdigest())
        return device if ok and re.fullmatch(r"[\w-]{1,32}", device) else None
    except (ValueError, AttributeError):
        return None


def throttled(table, who, limit, window):
    now = time.time()
    with _lock:
        q = [t for t in table.get(who, []) if now - t < window]
        table[who] = q
        return len(q) >= limit


def note(table, who):
    with _lock:
        table.setdefault(who, []).append(time.time())


# ---------------------------------------------------------------- upstream
class Bad(Exception):
    def __init__(self, msg, code=400):
        super().__init__(msg)
        self.code = code


def get_json(url, timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def gql(query, variables=None):
    req = urllib.request.Request(f"{OTP}/otp/gtfs/v1", method="POST", data=json.dumps({"query": query, "variables": variables or {}}).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        res = json.load(r)
    if res.get("errors"):
        raise Bad("routing engine: " + "; ".join(e.get("message", "?")[:120] for e in res["errors"][:2]), 502)
    return res["data"]


def num(s, lo, hi, name):
    try:
        v = float(s)
    except (TypeError, ValueError):
        raise Bad(f"{name} must be a number")
    if not lo <= v <= hi:
        raise Bad(f"{name} out of range")
    return v


def point(s, name):
    m = re.fullmatch(r"\s*(-?\d{1,2}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*", s or "")
    if not m:
        raise Bad(f"{name} must be 'lat,lon'")
    return num(m[1], -90, 90, name), num(m[2], -180, 180, name)


def local_iso(s):
    if not s:
        return datetime.datetime.now(TZ).replace(second=0, microsecond=0).isoformat()
    try:
        d = datetime.datetime.fromisoformat(s)
    except ValueError:
        raise Bad("time must be ISO, e.g. 2026-10-21T08:00")
    return (d if d.tzinfo else d.replace(tzinfo=TZ)).isoformat()


DUR = re.compile(r"(-)?P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?")


def seconds(v):
    """OTP gives delays as ISO-8601 durations ('PT3M20S', '-PT45S'); departures give plain integers."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return int(v)
    m = DUR.fullmatch(v)
    if not m:
        return None
    n = int(m[2] or 0) * 86400 + int(m[3] or 0) * 3600 + int(m[4] or 0) * 60 + float(m[5] or 0)
    return int(-n if m[1] else n)


def hhmm(sec):
    return f"{int(sec) // 3600 % 24:02d}:{int(sec) % 3600 // 60:02d}"


def sane_rt(scheduled, actual, delay, realtime):
    """a delay beyond 2 hours means the update hit the wrong service day (ZTP night lines): show the schedule."""
    if delay is None and actual is not None and scheduled is not None:
        delay = actual - scheduled
    if realtime and abs(delay or 0) > 7200:
        return {"time": hhmm(scheduled), "delay_s": None, "realtime": False}
    return {"time": hhmm(actual), "delay_s": delay if realtime else None, "realtime": bool(realtime)}


# ---------------------------------------------------------------- endpoints
def api_geocode(q):
    text = (q.get("q") or [""])[0].strip()[:120]
    if len(text) < 2:
        return []
    args = {"q": text, "format": "jsonv2", "limit": 7, "addressdetails": 1, "accept-language": "pl,en", "countrycodes": "pl,cz,sk"}
    if q.get("lat") and q.get("lon"):
        la, lo = point(f'{q["lat"][0]},{q["lon"][0]}', "bias")
        args["viewbox"] = f"{lo - 0.5},{la + 0.4},{lo + 0.5},{la - 0.4}"
    out = []
    for h in get_json(f"{NOM}/search?" + urllib.parse.urlencode(args)):
        a = h.get("address") or {}
        road = a.get("road") or a.get("pedestrian")
        title = h.get("name") or (f'{road} {a.get("house_number", "")}'.strip() if road else h["display_name"].split(",")[0])
        place = a.get("city") or a.get("town") or a.get("village") or a.get("municipality") or ""
        osm = {"node": "N", "way": "W", "relation": "R"}.get(h.get("osm_type"))
        poi = h.get("category") in places.MAIN_CLASSES and h.get("category") not in ("building", "place", "highway", "railway", "natural", "man_made")
        out.append({"title": title, "sub": ", ".join(x for x in (road if road and road != title else "", place) if x), "lat": float(h["lat"]), "lon": float(h["lon"]), "kind": h.get("type"),
                    "osm": f'{osm}{h["osm_id"]}' if osm and poi else None, "cat": places.label(h.get("category"), h.get("type")) if poi else None})
    return out


def api_reverse(q):
    la, lo = point(f'{(q.get("lat") or [""])[0]},{(q.get("lon") or [""])[0]}', "point")
    h = get_json(f"{NOM}/reverse?" + urllib.parse.urlencode({"lat": la, "lon": lo, "format": "jsonv2", "zoom": 18, "accept-language": "pl,en"}))
    a = h.get("address") or {}
    road = a.get("road") or a.get("pedestrian")
    title = h.get("name") or (f'{road} {a.get("house_number", "")}'.strip() if road else (h.get("display_name") or "Dropped pin").split(",")[0])
    return {"title": title, "sub": a.get("city") or a.get("town") or a.get("village") or "", "lat": la, "lon": lo}


LEG = """legs { mode duration distance realTime headsign
  from { name lat lon stop { gtfsId } } to { name lat lon stop { gtfsId } }
  start { scheduledTime estimated { time delay } } end { scheduledTime estimated { time delay } }
  route { shortName longName color textColor agency { name } }
  legGeometry { points }
  intermediateStops { name lat lon }
  trip { gtfsId }
  steps { relativeDirection streetName distance } }"""


def place(p):
    return {"name": p["name"], "lat": p["lat"], "lon": p["lon"], "stop_id": (p.get("stop") or {}).get("gtfsId")}


def leg_out(l):
    s, e = l["start"], l["end"]
    d = seconds((s.get("estimated") or {}).get("delay"))
    rt = bool(l.get("realTime")) and abs(d or 0) <= 7200
    out = {"mode": l["mode"], "from": place(l["from"]), "to": place(l["to"]), "distance_m": round(l["distance"]), "duration_s": round(l["duration"]),
           "start": (s.get("estimated") or {}).get("time") if rt and (s.get("estimated") or {}).get("time") else s["scheduledTime"],
           "end": (e.get("estimated") or {}).get("time") if rt and (e.get("estimated") or {}).get("time") else e["scheduledTime"],
           "scheduled_start": s["scheduledTime"], "scheduled_end": e["scheduledTime"], "realtime": rt, "delay_s": d if rt else None,
           "geometry": (l.get("legGeometry") or {}).get("points", "")}
    r = l.get("route")
    if r:
        out.update({"line": r.get("shortName") or r.get("longName"), "headsign": l.get("headsign"), "agency": (r.get("agency") or {}).get("name"),
                    "color": r.get("color"), "text_color": r.get("textColor"), "trip_id": (l.get("trip") or {}).get("gtfsId"),
                    "stops": [{"name": x["name"], "lat": x["lat"], "lon": x["lon"]} for x in (l.get("intermediateStops") or [])]})
    elif l.get("steps"):
        out["steps"] = [{"dir": x["relativeDirection"].lower(), "street": x["streetName"], "m": round(x["distance"])} for x in l["steps"][:60]]
    return out


HEADROOM_MODES = {"rail": "RAIL", "bus": "BUS", "tram": "TRAM"}


def parse_headrooms(q):
    """Parses transfer headroom in minutes per transit mode -> {MODE_NAME: seconds}."""
    res = {}
    for k, m in HEADROOM_MODES.items():
        v = (q.get(f"headroom_{k}") or [""])[0]
        if v:
            res[m] = int(num(v, 0, 180, f"headroom_{k}")) * 60
    comb = (q.get("headroom") or [""])[0]
    if comb:
        for part in comb.split(","):
            if ":" in part:
                k, val = part.split(":", 1)
                k = k.strip().lower()
                if k in HEADROOM_MODES:
                    res[HEADROOM_MODES[k]] = int(num(val.strip(), 0, 180, f"headroom {k}")) * 60
    return res


def check_transfer_headroom(legs, headroom):
    """Computes transfer headroom for each transfer leg.

    A transit leg is a transfer if there was a preceding transit leg in the journey.
    Headroom is the duration between arriving at the transfer platform (end of preceding leg)
    and departure of the transit leg (start of current leg).
    Annotates leg with 'transfer_headroom_s'.
    Returns True if all transfers satisfy any configured minimum headroom for that mode.
    """
    has_prior_transit = False
    ok = True
    for idx, leg in enumerate(legs):
        is_transit = bool(leg.get("line") or leg.get("mode") in ("RAIL", "BUS", "TRAM", "SUBWAY"))
        if is_transit:
            if has_prior_transit and idx > 0:
                prev_leg = legs[idx - 1]
                sched_headroom_s = None
                try:
                    t_curr_sched = datetime.datetime.fromisoformat(leg["scheduled_start"])
                    t_prev_sched = datetime.datetime.fromisoformat(prev_leg["scheduled_end"])
                    sched_headroom_s = round((t_curr_sched - t_prev_sched).total_seconds())
                except (KeyError, ValueError):
                    pass

                headroom_s = sched_headroom_s
                try:
                    t_curr = datetime.datetime.fromisoformat(leg["start"])
                    t_prev = datetime.datetime.fromisoformat(prev_leg["end"])
                    headroom_s = round((t_curr - t_prev).total_seconds())
                except (KeyError, ValueError):
                    pass

                effective_headroom = headroom_s if headroom_s is not None else sched_headroom_s
                leg["transfer_headroom_s"] = effective_headroom

                req_s = headroom.get(leg["mode"], 0)
                if req_s > 0:
                    if effective_headroom is not None and effective_headroom < req_s:
                        ok = False
                    elif sched_headroom_s is not None and sched_headroom_s < req_s:
                        ok = False
            has_prior_transit = True
    return ok


def api_plan(q):
    one = lambda k, d="": (q.get(k) or [d])[0]
    la, lo = point(one("from"), "from")
    ta, to = point(one("to"), "to")
    mode = one("mode", "transit")
    if mode != "transit" and mode not in DIRECT:
        raise Bad("mode must be transit, walk, bike or car")
    when = local_iso(one("at"))
    arrive = one("by") == "arrive"
    n = int(num(one("n", "3"), 1, 4, "n"))
    headroom = parse_headrooms(q) if mode == "transit" else {}
    has_headroom = any(v > 0 for v in headroom.values())
    fetch_n = max(n * 4, 12) if has_headroom else n
    dt = f'dateTime:{{{"latestArrival" if arrive else "earliestDeparture"}:"{when}"}}'
    if mode == "transit":
        picked = [TRANSIT[k] for k in one("transit", "rail,bus,tram").split(",") if k in TRANSIT]
        if not picked:
            raise Bad("pick at least one transit mode")
        modes = f'modes:{{transit:{{transit:[{",".join("{mode:" + m + "}" for m in picked)}]}}}}'
    else:
        modes, fetch_n = f"modes:{{directOnly:true,direct:[{DIRECT[mode]}]}}", 1  # a street search yields exactly one itinerary
    loc = lambda a, b: f"{{location:{{coordinate:{{latitude:{a},longitude:{b}}}}}}}"
    def run(dt_clause, count):
        query = f"{{ planConnection(origin:{loc(la, lo)} destination:{loc(ta, to)} {dt_clause} {modes} first:{count}) {{ edges {{ node {{ start end duration numberOfTransfers walkDistance {LEG} }} }} }} }}"
        return gql(query)["planConnection"]["edges"]

    edges, note = run(dt, fetch_n), None
    if not edges and arrive and mode == "transit":
        # nothing gets there in time within the search window: offer the closest ones and say how late they are
        before = (datetime.datetime.fromisoformat(when) - datetime.timedelta(hours=3)).isoformat()
        edges = run(f'dateTime:{{earliestDeparture:"{before}"}}', fetch_n)
        note = "Nothing arrives by then. These are the closest options."
    target = datetime.datetime.fromisoformat(when)
    out = []
    for e in edges:
        it = {"start": e["node"]["start"], "end": e["node"]["end"], "duration_s": round(e["node"]["duration"]),
              "transfers": e["node"]["numberOfTransfers"], "walk_m": round(e["node"].get("walkDistance") or 0),
              "legs": [leg_out(l) for l in e["node"]["legs"]]}
        late = round((datetime.datetime.fromisoformat(e["node"]["end"]) - target).total_seconds() / 60)
        if arrive and late > 0:
            it["late_min"] = late
        ok = check_transfer_headroom(it["legs"], headroom)
        if ok or not has_headroom:
            out.append(it)
        if len(out) >= n:
            break

    if has_headroom and not out and edges:
        labels = [f"{k}: {headroom[m] // 60}m" for k, m in HEADROOM_MODES.items() if headroom.get(m, 0) > 0]
        note = f"No routes found with the requested transfer headroom ({', '.join(labels)}). Try reducing headroom."

    return {"itineraries": out, "when": when, "by": "arrive" if arrive else "depart", "note": note}


def dep_rows(items):
    return [{"line": x["trip"]["route"]["shortName"], "agency": (x["trip"]["route"].get("agency") or {}).get("name"), "to": x["headsign"], "scheduled": hhmm(x["scheduledDeparture"]),
             **sane_rt(x["scheduledDeparture"], x["realtimeDeparture"], x["departureDelay"], x["realtime"]), "trip": x["trip"]["gtfsId"]} for x in items]


DEP = "stoptimesWithoutPatterns(numberOfDepartures:$n) { scheduledDeparture realtimeDeparture departureDelay realtime headsign trip { gtfsId route { shortName agency { name } } } }"


def api_nearby(q):
    la, lo = point(f'{(q.get("lat") or [""])[0]},{(q.get("lon") or [""])[0]}', "point")
    r = int(num((q.get("r") or ["500"])[0], 50, 1500, "r"))
    d = gql(f"{{ nearest(lat:{la}, lon:{lo}, maxDistance:{r}, filterByPlaceTypes:[STOP], first:12) {{ edges {{ node {{ distance place {{ ... on Stop {{ gtfsId name code lat lon "
            f"stoptimesWithoutPatterns(numberOfDepartures:3) {{ scheduledDeparture realtimeDeparture departureDelay realtime headsign trip {{ gtfsId route {{ shortName agency {{ name }} }} }} }} }} }} }} }} }} }}")
    return [{"id": p["gtfsId"], "name": p["name"], "code": p.get("code"), "lat": p["lat"], "lon": p["lon"], "distance_m": round(e["node"]["distance"]),
             "departures": dep_rows(p["stoptimesWithoutPatterns"])}
            for e in d["nearest"]["edges"] for p in [e["node"]["place"]] if p]


ID = re.compile(r"[\w:.\-/+]{1,100}")


def api_departures(q):
    sid = (q.get("stop") or [""])[0]
    if not ID.fullmatch(sid):
        raise Bad("bad stop id")
    n = int(num((q.get("n") or ["12"])[0], 1, 30, "n"))
    d = gql(f"query($id:String!,$n:Int!){{ stop(id:$id){{ name lat lon {DEP} }} }}", {"id": sid, "n": n})["stop"]
    if not d:
        raise Bad("unknown stop", 404)
    return {"name": d["name"], "lat": d["lat"], "lon": d["lon"], "departures": dep_rows(d["stoptimesWithoutPatterns"])}


def api_trip(q):
    tid = (q.get("id") or [""])[0]
    if not ID.fullmatch(tid):
        raise Bad("bad trip id")
    day = (q.get("date") or [datetime.datetime.now(TZ).strftime("%Y-%m-%d")])[0]
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
        raise Bad("date must be YYYY-MM-DD")
    d = gql("""query($id:String!,$d:String!){
        trip(id:$id){
            tripHeadsign
            tripGeometry { points }
            route { shortName longName color mode agency { name } }
            stoptimesForDate(serviceDate:$d){
                stop { name lat lon }
                scheduledArrival
                realtimeArrival
                arrivalDelay
                scheduledDeparture
                realtimeDeparture
                departureDelay
                realtime
            }
        }
    }""", {"id": tid, "d": day})["trip"]
    if not d:
        raise Bad("unknown trip", 404)
    stops = []
    for s in d.get("stoptimesForDate") or []:
        sched_d = s.get("scheduledDeparture") if s.get("scheduledDeparture") is not None else s.get("scheduledArrival")
        act_d = s.get("realtimeDeparture") if s.get("realtimeDeparture") is not None else s.get("realtimeArrival")
        del_s = s.get("departureDelay") if s.get("departureDelay") is not None else s.get("arrivalDelay")
        stops.append({
            "stop": s["stop"]["name"],
            "lat": s["stop"].get("lat"),
            "lon": s["stop"].get("lon"),
            "scheduled": hhmm(sched_d),
            **sane_rt(sched_d, act_d, del_s, s.get("realtime", False))
        })
    return {
        "line": d["route"]["shortName"],
        "color": d["route"].get("color"),
        "mode": d["route"].get("mode"),
        "agency": (d["route"].get("agency") or {}).get("name"),
        "to": d["tripHeadsign"],
        "geometry": (d.get("tripGeometry") or {}).get("points"),
        "stops": stops
    }


def api_info(_q):
    try:
        m = json.load(open(MANIFEST))
    except (OSError, ValueError):
        m = {}
    return {"built_at": m.get("built_at"), "osm_data": m.get("osm_data_timestamp"), "feeds": [{"id": f["id"], "attribution": f.get("attribution")} for f in m.get("feeds", [])],
            "attribution": m.get("attribution", "© OpenStreetMap contributors")}


# ---------------------------------------------------------------- live vehicles and trip shapes
SIG_FILE = os.environ.get("NAV_SIGNALS", os.path.join(os.path.dirname(MANIFEST), "signals.json"))
_veh = {"t": 0.0, "list": []}
_veh_lock = threading.Lock()
_shapes = {}
_sig = {"mtime": 0, "checked": 0, "grid": {}, "pts": []}
CELL = 0.0006


def decode_poly(s):
    i = lat = lon = 0
    out = []
    while i < len(s):
        for axis in (0, 1):
            shift = result = 0
            while True:
                b = ord(s[i]) - 63
                i += 1
                result |= (b & 31) << shift
                shift += 5
                if b < 32:
                    break
            d = ~(result >> 1) if result & 1 else result >> 1
            if axis == 0:
                lat += d
            else:
                lon += d
        out.append((lon / 1e5, lat / 1e5))
    return out


def signals():
    """traffic signal nodes from the desktop build (signals.json, [[lon, lat], ...]); empty when the build had none."""
    now = time.time()
    if now - _sig["checked"] > 60:
        _sig["checked"] = now
        try:
            m = os.stat(SIG_FILE).st_mtime
            if m != _sig["mtime"]:
                with open(SIG_FILE) as f:
                    pts = [(float(a), float(b)) for a, b in json.load(f)[:60000]]
                grid = {}
                for n, (lo, la) in enumerate(pts):
                    grid.setdefault((int(lo / CELL), int(la / CELL)), []).append(n)
                _sig.update(mtime=m, grid=grid, pts=pts)
        except (OSError, ValueError, TypeError):
            pass
    return _sig


VEH_Q = """{ routes { shortName mode agency { name } patterns { vehiclePositions { vehicleId lat lon heading speed lastUpdated
  stopRelationship { status stop { name } } trip { gtfsId tripHeadsign } } } } }"""


def vehicles_snapshot():
    with _veh_lock:
        if time.time() - _veh["t"] < 4:
            return _veh["list"]
        seen, out = set(), []
        for r in gql(VEH_Q)["routes"]:
            for p in r["patterns"]:
                for v in p["vehiclePositions"] or []:
                    if v["vehicleId"] in seen or v.get("lat") is None:
                        continue
                    seen.add(v["vehicleId"])
                    rel = v.get("stopRelationship") or {}
                    out.append({"id": v["vehicleId"], "lat": v["lat"], "lon": v["lon"], "hd": v.get("heading"), "sp": v.get("speed"), "ts": v.get("lastUpdated"),
                                "trip": (v.get("trip") or {}).get("gtfsId"), "to": (v.get("trip") or {}).get("tripHeadsign"), "line": r["shortName"], "mode": r["mode"],
                                "ag": (r.get("agency") or {}).get("name"), "st": rel.get("status"), "sn": ((rel.get("stop") or {}).get("name"))})
        _veh.update(t=time.time(), list=out)
        return out


def api_vehicles(q):
    trip = (q.get("trip") or [""])[0]
    if trip:  # one vehicle by trip id, wherever it is
        if not ID.fullmatch(trip):
            raise Bad("bad trip id")
        return {"now": time.time(), "vehicles": [v for v in vehicles_snapshot() if v["trip"] == trip][:3]}
    raw = (q.get("bbox") or [""])[0]
    box = [float(x) for x in raw.split(",")] if raw else []
    if len(box) != 4 or not (-180 <= box[0] < box[2] <= 180 and -90 <= box[1] < box[3] <= 90):
        raise Bad("bbox must be minLon,minLat,maxLon,maxLat")
    inside = [v for v in vehicles_snapshot() if box[0] <= v["lon"] <= box[2] and box[1] <= v["lat"] <= box[3]]
    if (q.get("lod") or [""])[0] == "heat":  # far zoom: positions only, any extent
        return {"now": time.time(), "heat": [[round(v["lon"], 4), round(v["lat"], 4)] for v in inside[:6000]]}
    if (box[2] - box[0]) > 1.5 or (box[3] - box[1]) > 1.0:
        return {"now": time.time(), "vehicles": [], "note": "zoom in to see vehicles"}
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    inside.sort(key=lambda v: (v["lon"] - cx) ** 2 + (v["lat"] - cy) ** 2)
    return {"now": time.time(), "vehicles": inside[:700]}


def seg_proj(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    t = 0.0 if l2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
    return t, math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def shape_info(trip_id):
    d = gql("query($id:String!){ trip(id:$id){ tripGeometry { points } stops { name lat lon } } }", {"id": trip_id})["trip"]
    if not d or not d.get("tripGeometry"):
        raise Bad("unknown trip", 404)
    pts = decode_poly(d["tripGeometry"]["points"])
    k = math.cos(math.radians(pts[0][1]))
    xy = [(lo * k * 111320.0, la * 110540.0) for lo, la in pts]
    cum = [0.0]
    for i in range(1, len(xy)):
        cum.append(cum[-1] + math.hypot(xy[i][0] - xy[i - 1][0], xy[i][1] - xy[i - 1][1]))
    stops, every, floor = [], [], 0.0
    for st in d["stops"] or []:
        px, py = st["lon"] * k * 111320.0, st["lat"] * 110540.0
        best = (1e18, 0.0)
        for i in range(len(xy) - 1):
            t, dd = seg_proj(px, py, *xy[i], *xy[i + 1])
            if dd < best[0]:
                best = (dd, cum[i] + t * (cum[i + 1] - cum[i]))
        if best[0] < 80:
            stops.append({"n": st["name"], "a": round(best[1])})
        floor = max(floor, best[1])  # trip order is travel order, so distances never go back
        every.append(round(floor))
    sg = signals()
    hit = {}
    for i in range(len(xy) - 1):
        (ax, ay), (bx, by) = xy[i], xy[i + 1]
        lo0, lo1 = sorted((pts[i][0], pts[i + 1][0]))
        la0, la1 = sorted((pts[i][1], pts[i + 1][1]))
        for cx in range(int(lo0 / CELL) - 1, int(lo1 / CELL) + 2):
            for cy in range(int(la0 / CELL) - 1, int(la1 / CELL) + 2):
                for n in sg["grid"].get((cx, cy), ()):
                    sx, sy = sg["pts"][n][0] * k * 111320.0, sg["pts"][n][1] * 110540.0
                    t, dd = seg_proj(sx, sy, ax, ay, bx, by)
                    if dd <= 14 and (n not in hit or dd < hit[n][0]):
                        hit[n] = (dd, cum[i] + t * (cum[i + 1] - cum[i]))
    lights = sorted({round(a) for _, a in hit.values() if 15 < a < cum[-1] - 15})
    merged = []
    for a in lights:  # one junction can hold several signal nodes
        if not merged or a - merged[-1] > 25:
            merged.append(a)
    return {"points": d["tripGeometry"]["points"], "length": round(cum[-1]), "stops": stops, "sig": merged, "all": every}


def cached_shape(tid):
    hit = _shapes.get(tid)
    if hit and time.time() - hit[0] < 6 * 3600:
        return hit[1]
    info = shape_info(tid)
    if len(_shapes) > 800:
        for k in sorted(_shapes, key=lambda x: _shapes[x][0])[:200]:
            _shapes.pop(k, None)
    _shapes[tid] = (time.time(), info)
    return info


def api_shape(q):
    tid = (q.get("trip") or [""])[0]
    if not ID.fullmatch(tid):
        raise Bad("bad trip id")
    return cached_shape(tid)


# ---------------------------------------------------------------- scheduled trips (vehicles with no live position, played back from the timetable)
SCHED_STOPS, SCHED_TRIPS = 45, 80
_sched = {}


def api_sched(q):
    raw = (q.get("bbox") or [""])[0]
    box = [float(x) for x in raw.split(",")] if raw else []
    if len(box) != 4 or not (-180 <= box[0] < box[2] <= 180 and -90 <= box[1] < box[3] <= 90):
        raise Bad("bbox must be minLon,minLat,maxLon,maxLat")
    if box[2] - box[0] > 1.5 or box[3] - box[1] > 1.0:
        return {"now": time.time(), "trips": [], "note": "zoom in"}
    at = int(num((q.get("at") or [str(int(time.time()))])[0], time.time() - 365 * 86400, time.time() + 365 * 86400, "at"))
    everything = (q.get("all") or [""])[0] == "1"  # a time other than now: the live feed says nothing about it
    gap = (q.get("gap") or [""])[0] == "1"  # only operators with no live positions at all (trains, trams without a feed): their vehicles are estimated from schedule and delay
    key = (round(box[0], 3), round(box[1], 3), round(box[2], 3), round(box[3], 3), at // 30, everything, gap)
    hit = _sched.get(key)
    if hit and time.time() - hit[0] < 20:
        return hit[1]
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    st = gql("query($a:Float!,$b:Float!,$c:Float!,$d:Float!){ stopsByBbox(minLat:$a, minLon:$b, maxLat:$c, maxLon:$d){ gtfsId lat lon vehicleMode } }", {"a": box[1], "b": box[0], "c": box[3], "d": box[2]})["stopsByBbox"]
    st.sort(key=lambda x: (x["lon"] - cx) ** 2 + (x["lat"] - cy) ** 2)
    if gap:
        rail_stops = [x for x in st if "plk" in x["gtfsId"].lower() or "rail" in str(x.get("vehicleMode") or "").lower()]
        other_stops = [x for x in st if x not in rail_stops]
        st = rail_stops + other_stops
    ids = [x["gtfsId"] for x in st[:SCHED_STOPS] if ID.fullmatch(x["gtfsId"])]
    out = {"now": time.time(), "at": at, "trips": []}
    if not ids:
        return out
    part = " ".join(f's{i}: stop(id:{json.dumps(sid)}) {{ stoptimesWithoutPatterns(startTime:{at - 2400}, timeRange:6000, numberOfDepartures:40) {{ serviceDay trip {{ gtfsId }} }} }}' for i, sid in enumerate(ids))
    seen = {}
    for blk in gql("{ " + part + " }").values():
        for x in (blk or {}).get("stoptimesWithoutPatterns") or []:
            seen.setdefault(x["trip"]["gtfsId"], x["serviceDay"])
    live_agencies = set()
    if not everything:
        snap = vehicles_snapshot()
        live = {v["trip"] for v in snap if v["trip"]}
        live_agencies = {v.get("ag") for v in snap if v.get("ag")}
        seen = {t: d for t, d in seen.items() if t not in live}
    chosen = [(t, d) for t, d in seen.items() if ID.fullmatch(t)][:SCHED_TRIPS]
    if not chosen:
        return out
    part = " ".join(f't{i}: trip(id:{json.dumps(t)}) {{ tripHeadsign route {{ shortName mode agency {{ name }} }} stoptimesForDate(serviceDate:{json.dumps(datetime.datetime.fromtimestamp(d, TZ).strftime("%Y-%m-%d"))}) {{ scheduledArrival scheduledDeparture realtimeArrival realtimeDeparture }} }}' for i, (t, d) in enumerate(chosen))
    res = gql("{ " + part + " }")
    for i, (t, d) in enumerate(chosen):
        tr = res.get(f"t{i}")
        times = (tr or {}).get("stoptimesForDate") or []
        if len(times) < 2:
            continue
        if gap and (tr["route"].get("agency") or {}).get("name") in live_agencies:
            continue
        dep0 = times[0]["realtimeDeparture"] if times[0].get("realtimeDeparture") is not None else times[0].get("scheduledDeparture", 0)
        arr1 = times[-1]["realtimeArrival"] if times[-1].get("realtimeArrival") is not None else times[-1].get("scheduledArrival", 0)
        a0, a1 = d + dep0, d + arr1
        if a1 < at - 30 or a0 > at + 300:
            continue
        try:
            sh = cached_shape(t)
        except Bad:
            continue
        along = sh.get("all") or []
        if len(along) != len(times):
            continue
        st_list = []
        for j, x in enumerate(times):
            arr = x.get("realtimeArrival") if x.get("realtimeArrival") is not None else x.get("scheduledArrival", 0)
            dep = x.get("realtimeDeparture") if x.get("realtimeDeparture") is not None else x.get("scheduledDeparture", 0)
            st_list.append([along[j], arr, dep])
        out["trips"].append({"trip": t, "line": tr["route"]["shortName"], "mode": tr["route"]["mode"], "ag": (tr["route"].get("agency") or {}).get("name"), "to": tr["tripHeadsign"], "sd": d,
                             "st": st_list})
    if len(_sched) > 60:
        _sched.clear()
    _sched[key] = (time.time(), out)
    return out


# ---------------------------------------------------------------- roof shapes (OSM roof:shape)
# Served from roofs.json next to the graph manifest when the build produced one; otherwise fetched from Overpass cell by cell in the background.
ROOF_FILE = os.environ.get("NAV_ROOFS", os.path.join(os.path.dirname(MANIFEST), "roofs.json"))
OVERPASS = ("https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter", "https://overpass.private.coffee/api/interpreter")
ROOF_CELL = 0.01
_roofs = {}
_roof_busy = set()
_roof_file = {"mtime": None, "grid": {}}
_roof_lock = threading.Lock()  # one Overpass request at a time, as its usage policy asks


def _num(v):
    if isinstance(v, (int, float)):
        return float(v)
    m = re.match(r"\s*(\d+(?:[.,]\d+)?)", v or "")
    return float(m.group(1).replace(",", ".")) if m else None


def roof_way(wid, t, ring):
    shape = t.get("roof:shape")
    if not t.get("building") or not shape or shape == "flat" or not 4 <= len(ring) <= 60:
        return None
    return {"id": wid, "shape": shape[:20], "h": _num(t.get("height") or t.get("building:height")), "lv": _num(t.get("building:levels")), "rh": _num(t.get("roof:height")),
            "rlv": _num(t.get("roof:levels")), "col": (t.get("roof:colour") or "")[:20] or None, "mat": (t.get("roof:material") or "")[:20] or None, "dir": _num(t.get("roof:direction")),
            "pts": [[round(x, 6), round(y, 6)] for x, y in ring]}


def roof_ways(elements):
    out = []
    for e in elements:
        w = e.get("type") == "way" and roof_way(e["id"], e.get("tags") or {}, [(p["lon"], p["lat"]) for p in e.get("geometry") or []])
        if w:
            out.append(w)
    return out


def roof_grid():
    """The build artefact indexed by cell of the first vertex, or None when there is no file."""
    try:
        m = os.stat(ROOF_FILE).st_mtime
    except OSError:
        return None
    if _roof_file["mtime"] != m:
        grid = {}
        try:
            for w in json.load(open(ROOF_FILE)):
                w["pts"] = [[x, y] for x, y in w["pts"]]
                for k in ("h", "lv", "rh", "rlv", "dir"):
                    w[k] = _num(w.get(k))
                grid.setdefault((math.floor(w["pts"][0][0] / ROOF_CELL), math.floor(w["pts"][0][1] / ROOF_CELL)), []).append(w)
        except (OSError, ValueError, KeyError, TypeError):
            return None
        _roof_file.update(mtime=m, grid=grid)
    return _roof_file["grid"]


def _overpass_cell(cx, cy):
    w, s_, e, n = cx * ROOF_CELL, cy * ROOF_CELL, (cx + 1) * ROOF_CELL, (cy + 1) * ROOF_CELL
    q = f'[out:json][timeout:60];way["roof:shape"]({s_},{w},{n},{e});out tags geom 1500;'
    ways, ok = [], False
    with _roof_lock:
        for url in OVERPASS:
            try:
                req = urllib.request.Request(url, data=urllib.parse.urlencode({"data": q}).encode(), headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=70) as r:
                    ways = roof_ways(json.load(r).get("elements", []))
                ok = True
                break
            except (OSError, ValueError):
                continue
    if len(_roofs) > 400:
        _roofs.clear()
    _roofs[(cx, cy)] = (time.time() + (24 * 3600 if ok else 120), ways, ok)
    _roof_busy.discard((cx, cy))


def roof_cell(cx, cy):
    """(ways, ready): a cell not known yet starts a background fetch and is not ready."""
    grid = roof_grid()
    if grid is not None:
        return grid.get((cx, cy), []), True
    hit = _roofs.get((cx, cy))
    if hit and time.time() < hit[0]:
        return hit[1], hit[2]
    if (cx, cy) not in _roof_busy:
        _roof_busy.add((cx, cy))
        threading.Thread(target=_overpass_cell, args=(cx, cy), daemon=True).start()
    return (hit[1] if hit else []), False


def api_roofs(q):
    raw = (q.get("cells") or [""])[0]
    cells = []
    for part in raw.split(";")[:6]:
        try:
            cx, cy = (int(x) for x in part.split(","))
        except ValueError:
            raise Bad("cells must be cx,cy;cx,cy")
        if not (-18000 <= cx <= 18000 and -9000 <= cy <= 9000):
            raise Bad("cell out of range")
        cells.append((cx, cy))
    seen, out, ready = set(), [], []
    for c in cells:
        ways, ok = roof_cell(*c)
        if ok:
            ready.append(f"{c[0]},{c[1]}")
        for w in ways:
            if w["id"] not in seen:
                seen.add(w["id"])
                out.append(w)
    return {"ways": out, "ready": ready, "attribution": "© OpenStreetMap contributors"}


# ---------------------------------------------------------------- elevation tiles (Terrarium PNG from the AWS open data set), proxied so the page stays same-origin
DEM_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
_dem = collections.OrderedDict()
_dem_lock = threading.Lock()
DEM_KEEP = 400


def dem_tile(z, x, y):
    if not (0 <= z <= 15 and 0 <= x < 2 ** z and 0 <= y < 2 ** z):
        raise Bad("tile out of range")
    key = (z, x, y)
    with _dem_lock:
        if key in _dem:
            _dem.move_to_end(key)
            return _dem[key]
    req = urllib.request.Request(DEM_URL.format(z=z, x=x, y=y), headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = r.read(800_000)
    if not data.startswith(b"\x89PNG"):
        raise Bad("not a tile", 502)
    with _dem_lock:
        _dem[key] = data
        while len(_dem) > DEM_KEEP:
            _dem.popitem(last=False)
    return data



# ---------------------------------------------------------------- places (explore)
def api_explore(q):
    one = lambda k, d="": (q.get(k) or [d])[0]
    la, lo = point(f'{one("lat")},{one("lon")}', "point")
    try:
        return places.explore(one("cat", "all") or "all", la, lo, num(one("r", "800"), 100, 3000, "r"))
    except ValueError as e:
        raise Bad(str(e))



def place_args(q):
    one = lambda k, d="": (q.get(k) or [d])[0]
    if one("id"):
        if not places.OSM_ID.fullmatch(one("id")):
            raise Bad("bad place id")
        return {"osm": one("id")}
    la, lo = point(f'{one("lat")},{one("lon")}', "point")
    return {"lat": la, "lon": lo, "name": one("name")[:120] or None}


def api_place(q, device="web"):
    card = places.place_card(**place_args(q))
    if not card:
        raise Bad("no place here", 404)
    if DB:
        with conn() as c:
            card["saved"] = bool(c.execute("SELECT 1 FROM saved WHERE device=? AND id=?", (device, card["id"])).fetchone())
            n = c.execute("SELECT rating, text, ts FROM notes WHERE device=? AND place=?", (device, card["id"])).fetchone()
            card["note"] = dict(n) if n else None
    return card


def api_place_more(q):
    card = places.place_card(**place_args(q))
    if not card:
        raise Bad("no place here", 404)
    out = places.more(card)
    if out.get("photo"):
        out["photo"] = "/api/img?u=" + urllib.parse.quote(out["photo"], safe="")
    return out


def api_saved_list(device):
    with conn() as c:
        return [dict(r) for r in c.execute("SELECT id, title, lat, lon, cat FROM saved WHERE device=? ORDER BY ts DESC LIMIT 200", (device,)).fetchall()]


def api_saved_add(device, b):
    pid, title = str(b.get("id", ""))[:40], str(b.get("title", ""))[:120]
    la, lo = point(f'{b.get("lat")},{b.get("lon")}', "point")
    if not pid or not title:
        raise Bad("id and title are required")
    with conn() as c:
        c.execute("INSERT OR REPLACE INTO saved VALUES (?,?,?,?,?,?,?)", (device, pid, title, la, lo, str(b.get("cat", ""))[:40], time.time()))
    return {"ok": True}


def api_note_set(device, b):
    place = str(b.get("place", ""))[:40]
    rating = int(num(b.get("rating", 0), 0, 5, "rating"))
    text = str(b.get("text", ""))[:1500]
    if not place:
        raise Bad("place is required")
    with conn() as c:
        if rating == 0 and not text:
            c.execute("DELETE FROM notes WHERE device=? AND place=?", (device, place))
        else:
            c.execute("INSERT OR REPLACE INTO notes VALUES (?,?,?,?,?)", (device, place, rating, text, time.time()))
    return {"ok": True}


_weather = {}


def wmo_to_condition(code, cloud=0):
    if code == 0:
        return "clear"
    elif code in (1, 2):
        return "cloudy" if cloud > 50 else "clear"
    elif code == 3:
        return "cloudy"
    elif code in (45, 48):
        return "fog"
    elif (51 <= code <= 67) or (80 <= code <= 82):
        return "rain"
    elif (71 <= code <= 77) or (85 <= code <= 86):
        return "snow"
    elif code in (95, 96, 99):
        return "thunderstorm"
    return "clear"


def api_weather(q):
    if "lat" not in q or "lon" not in q:
        raise Bad("lat and lon are required")
    try:
        lat = float((q.get("lat") or [""])[0])
        lon = float((q.get("lon") or [""])[0])
    except (ValueError, TypeError):
        raise Bad("lat and lon must be numbers")
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise Bad("lat or lon out of range")
    key = (round(lat, 2), round(lon, 2))
    hit = _weather.get(key)
    if hit and time.time() - hit[0] < 600:
        return hit[1]
    url = f"https://api.open-meteo.com/v1/forecast?latitude={lat:.4f}&longitude={lon:.4f}&current=temperature_2m,relative_humidity_2m,precipitation,weather_code,cloud_cover,wind_speed_10m"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "KowalNav/1.0"})
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode())
        cur = data.get("current") or {}
        code = cur.get("weather_code", 0)
        cloud = cur.get("cloud_cover", 0)
        cond = wmo_to_condition(code, cloud)
        res = {
            "ok": True,
            "condition": cond,
            "code": code,
            "wmo": code,
            "temp": cur.get("temperature_2m", 15.0),
            "cloud": cloud,
            "precip": cur.get("precipitation", 0),
            "wind": cur.get("wind_speed_10m", 0),
        }
    except Exception:
        res = {
            "ok": True,
            "condition": "clear",
            "code": 0,
            "wmo": 0,
            "temp": 16.0,
            "cloud": 20,
            "precip": 0,
            "wind": 5.0,
            "simulated": True,
        }
    _weather[key] = (time.time(), res)
    return res


ROUTES = {"/api/explore": api_explore, "/api/place/more": api_place_more, "/api/vehicles": api_vehicles, "/api/shape": api_shape, "/api/sched": api_sched, "/api/roofs": api_roofs, "/api/geocode": api_geocode, "/api/reverse": api_reverse, "/api/plan": api_plan, "/api/nearby": api_nearby,
          "/api/departures": api_departures, "/api/trip": api_trip, "/api/info": api_info, "/api/weather": api_weather}


# ---------------------------------------------------------------- watched trips (groundwork for push and native clients)
# A client registers the transit legs of its trip. The watcher compares live delays once a minute and appends events,
# which a client polls from /api/v1/events. Delivery over Web Push or FCM plugs in at emit() later.
def conn():
    c = sqlite3.connect(DB, timeout=5)
    c.row_factory = sqlite3.Row
    return c


def init_db():
    with conn() as c:
        c.executescript("""
            CREATE TABLE IF NOT EXISTS watches (id TEXT PRIMARY KEY, device TEXT, until REAL, legs TEXT, last TEXT);
            CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, watch TEXT, device TEXT, ts REAL, kind TEXT, text TEXT);
            CREATE TABLE IF NOT EXISTS pushes (device TEXT PRIMARY KEY, kind TEXT, target TEXT);
            CREATE TABLE IF NOT EXISTS saved (device TEXT, id TEXT, title TEXT, lat REAL, lon REAL, cat TEXT, ts REAL, PRIMARY KEY (device, id));
            CREATE TABLE IF NOT EXISTS notes (device TEXT, place TEXT, rating INTEGER, text TEXT, ts REAL, PRIMARY KEY (device, place));""")


def emit(c, watch, device, kind, text):
    c.execute("INSERT INTO events (watch, device, ts, kind, text) VALUES (?,?,?,?,?)", (watch, device, time.time(), kind, text))
    # delivery hook: look up pushes[device] and send over its kind, not implemented yet


def watch_once():
    with conn() as c:
        c.execute("DELETE FROM watches WHERE until < ?", (time.time(),))
        c.execute("DELETE FROM events WHERE ts < ?", (time.time() - 86400,))
        for w in c.execute("SELECT * FROM watches").fetchall():
            legs, last = json.loads(w["legs"]), json.loads(w["last"] or "{}")
            for i, l in enumerate(legs):
                try:
                    day = l["scheduled_start"][:10]
                    t = api_trip({"id": [l["trip_id"]], "date": [day]})
                except Exception:
                    continue
                at = next((x for x in t["stops"] if x["stop"] == l["from"]), None)
                if not at:
                    continue
                delay = at["delay_s"] if at["realtime"] else None
                prev = last.get(str(i), {"delay": 0, "live": False})
                if delay is not None and (not prev["live"] or abs(delay - prev["delay"]) >= 120):
                    mins = round(delay / 60)
                    emit(c, w["id"], w["device"], "delay", f'{l["line"]} at {l["from"]}: ' + (f"{mins} min late" if mins > 0 else "on time" if mins == 0 else f"{-mins} min early"))
                last[str(i)] = {"delay": delay if delay is not None else prev["delay"], "live": delay is not None or prev["live"]}
            c.execute("UPDATE watches SET last=? WHERE id=?", (json.dumps(last), w["id"]))


def watch_loop():
    while True:
        try:
            watch_once()
        except Exception:
            pass
        time.sleep(60)


def api_watch_add(device, body):
    legs = [{k: str(l.get(k, ""))[:120] for k in ("trip_id", "line", "from", "to", "scheduled_start")} for l in (body.get("legs") or [])[:8] if ID.fullmatch(str(l.get("trip_id", "")))]
    if not legs:
        raise Bad("no transit legs to watch")
    wid = hashlib.sha256(os.urandom(16)).hexdigest()[:16]
    until = time.time() + min(float(body.get("hours", 6)), 24) * 3600
    with conn() as c:
        if c.execute("SELECT COUNT(*) FROM watches WHERE device=?", (device,)).fetchone()[0] >= 5:
            raise Bad("too many watched trips")
        c.execute("INSERT INTO watches (id, device, until, legs, last) VALUES (?,?,?,?,?)", (wid, device, until, json.dumps(legs), "{}"))
    return {"id": wid, "until": until}


def api_events(device, q):
    since = int(num((q.get("since") or ["0"])[0], 0, 1e12, "since"))
    with conn() as c:
        rows = c.execute("SELECT id, watch, ts, kind, text FROM events WHERE device=? AND id>? ORDER BY id LIMIT 100", (device, since)).fetchall()
    return [dict(r) for r in rows]


# ---------------------------------------------------------------- http
_build_cache = {"key": None, "id": ""}


def build_id():
    """content hash of the shipped files; recomputed when one of them changes on disk (matters in development, deploys replace the store path)."""
    names = ("index.html", "app.js", "vehicles.js", "guide.js", "explore.js", "scene3d.js", "daylight.js", "diorama.js", "fleet.js", "traffic.js", "world.js", "dem.js", "sched.js", "roofs.js", "roads3d.js", "app.css", "providers.json", "sw.js")
    key = []
    for n in names:
        try:
            st = os.stat(os.path.join(STATIC, n))
            key.append((n, st.st_mtime_ns, st.st_size))
        except OSError:
            key.append((n, 0, 0))
    if key != _build_cache["key"]:
        h = hashlib.sha1()
        for n in names:
            try:
                with open(os.path.join(STATIC, n), "rb") as f:
                    h.update(f.read())
            except OSError:
                pass
        _build_cache.update(key=key, id=h.hexdigest()[:10])
    return _build_cache["id"]




class H(BaseHTTPRequestHandler):
    server_version = "nav"
    sys_version = ""

    def log_message(self, *_):  # no request lines: they would carry coordinates
        pass

    def who(self):
        return self.headers.get("Cf-Connecting-Ip") or self.client_address[0]

    def send(self, code, body=b"", ctype="application/json", extra=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "geolocation=(self), camera=(), microphone=()")
        nocache = ctype == "application/json" or ctype.startswith("text/html")
        cc = [v for k, v in extra if k == "Cache-Control"]
        self.send_header("Cache-Control", "no-store" if nocache else (cc[0] if cc else "no-cache"))
        if nocache:  # a CDN must never keep the page or an API answer
            self.send_header("CDN-Cache-Control", "no-store")
            self.send_header("Cloudflare-CDN-Cache-Control", "no-store")
        for k, v in extra:
            if k != "Cache-Control":
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def j(self, code, obj, extra=()):
        self.send(code, json.dumps(obj, ensure_ascii=False).encode(), extra=extra)

    def device(self):
        """device name of the signed cookie or bearer token, None when not signed in."""
        if not SECRET:
            return None
        b = self.headers.get("Authorization", "")
        if b.lower().startswith("bearer "):
            return session_device(b[7:].strip())
        m = re.search(r"(?:^|;\s*)nav=([^;]+)", self.headers.get("Cookie", ""))
        return session_device(m[1]) if m else None

    def authed(self):
        return self.device() is not None

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path.startswith("/api/v1/"):  # the versioned contract for other clients; /api/ stays what the web app calls
            u = u._replace(path="/api/" + u.path[8:])
        if u.path == "/healthz":
            return self.j(200, {"ok": True, "build": build_id()})
        if u.path.startswith("/api/"):
            if u.path == "/api/session":
                return self.j(200 if self.authed() else 401, {"ok": self.authed()})
            if u.path == "/api/img":
                if not self.authed():
                    return self.j(401, {"error": "sign in"})
                try:
                    ctype, data = places.fetch_image((urllib.parse.parse_qs(u.query).get("u") or [""])[0])
                except Exception:
                    return self.j(404, {"error": "no image"})
                return self.send(200, data, ctype, extra=[("Cache-Control", "private, max-age=86400")])
            if u.path == "/api/dem":
                if not self.authed():
                    return self.j(401, {"error": "sign in"})
                who = self.who() + "|bulk"
                if throttled(_hits, who, 900, 60):
                    return self.j(429, {"error": "slow down"})
                note(_hits, who)
                try:
                    q = urllib.parse.parse_qs(u.query)
                    data = dem_tile(*(int((q.get(k) or ["-1"])[0]) for k in ("z", "x", "y")))
                except Bad as e:
                    return self.j(e.code, {"error": str(e)})
                except Exception:
                    return self.j(502, {"error": "elevation unavailable"})
                return self.send(200, data, "image/png", extra=[("Cache-Control", "private, max-age=604800")])
            if u.path in ("/api/place", "/api/saved") and DB:
                if not self.authed():
                    return self.j(401, {"error": "sign in"})
                try:
                    q = urllib.parse.parse_qs(u.query)
                    return self.j(200, api_place(q, self.device()) if u.path == "/api/place" else api_saved_list(self.device()))
                except Bad as e:
                    return self.j(e.code, {"error": str(e)})
                except Exception:
                    return self.j(502, {"error": "places unavailable"})
            if u.path == "/api/events":
                if not DB:
                    return self.j(404, {"error": "not enabled"})
                if not self.authed():
                    return self.j(401, {"error": "sign in"})
                return self.j(200, api_events(self.device(), urllib.parse.parse_qs(u.query)))
            fn = ROUTES.get(u.path)
            if not fn:
                return self.j(404, {"error": "not found"})
            if not self.authed():
                return self.j(401, {"error": "sign in"})
            # cached, read-only map data (vehicles, trip shapes) gets its own larger bucket
            bulk = u.path in ("/api/vehicles", "/api/shape", "/api/sched", "/api/roofs")
            who = self.who() + ("|bulk" if bulk else "")
            if throttled(_hits, who, 900 if bulk else PER_MINUTE, 60):
                return self.j(429, {"error": "slow down"})
            note(_hits, who)
            try:
                return self.j(200, fn(urllib.parse.parse_qs(u.query)))
            except Bad as e:
                return self.j(e.code, {"error": str(e)})
            except Exception:
                return self.j(502, {"error": "upstream unavailable"})
        return self.static(u.path, versioned=bool(re.fullmatch(r"v=[0-9a-f]{10}", u.query)))

    def page(self):
        """index.html with the build id on every asset URL, so no proxy, CDN or service worker can serve an old script next to a new page."""
        BUILD = build_id()
        with open(os.path.join(STATIC, "index.html"), encoding="utf-8") as f:
            html = f.read()
        for n in ("app.css", "app.js", "vehicles.js", "guide.js", "explore.js", "scene3d.js", "daylight.js", "diorama.js", "fleet.js", "traffic.js", "world.js", "dem.js", "sched.js", "roofs.js", "roads3d.js"):
            html = html.replace(f'"/{n}"', f'"/{n}?v={BUILD}"')
        return html.replace('content="dev"', f'content="{BUILD}"').encode()

    def static(self, path, versioned=False):
        if path in ("/", "", "/index.html"):
            return self.send(200, self.page(), "text/html; charset=utf-8")
        rel = path.lstrip("/")
        full = os.path.realpath(os.path.join(STATIC, rel))
        if not full.startswith(os.path.realpath(STATIC) + os.sep) or not os.path.isfile(full):
            full = os.path.join(STATIC, "index.html")  # single page app: unknown paths fall back to the shell
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if full.endswith(".webmanifest"):
            ctype = "application/manifest+json"
        with open(full, "rb") as f:
            self.send(200, f.read(), ctype + ("; charset=utf-8" if ctype.startswith("text/") or "javascript" in ctype else ""), extra=[("Cache-Control", "public, max-age=31536000, immutable")] if versioned else ())

    def body(self, limit=8192):
        try:
            return json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", "0")), limit)) or b"{}")
        except ValueError:
            return {}

    def do_DELETE(self):
        u = urllib.parse.urlparse(self.path)
        p = u.path.replace("/api/v1/", "/api/")
        if p not in ("/api/watch", "/api/saved") or not DB or not self.authed():
            return self.j(404 if self.authed() else 401, {"error": "not found"})
        wid = (urllib.parse.parse_qs(u.query).get("id") or [""])[0]
        with conn() as c:
            c.execute("DELETE FROM watches WHERE id=? AND device=?" if p == "/api/watch" else "DELETE FROM saved WHERE id=? AND device=?", (wid, self.device()))
        return self.j(200, {"ok": True})

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/api/v1/"):
            path = "/api/" + path[8:]
        if path == "/api/logout":
            return self.j(200, {"ok": True}, extra=[("Set-Cookie", "nav=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Strict")])
        if path in ("/api/saved", "/api/notes"):
            if not DB or not self.authed():
                return self.j(401 if not self.authed() else 404, {"error": "not available"})
            try:
                b = self.body()
                return self.j(200, api_saved_add(self.device(), b) if path == "/api/saved" else api_note_set(self.device(), b))
            except Bad as e:
                return self.j(e.code, {"error": str(e)})
        if path in ("/api/watch", "/api/push"):
            if not DB:
                return self.j(404, {"error": "not enabled"})
            if not self.authed():
                return self.j(401, {"error": "sign in"})
            try:
                body = self.body()
                if path == "/api/watch":
                    return self.j(200, api_watch_add(self.device(), body))
                with conn() as c:
                    c.execute("INSERT OR REPLACE INTO pushes (device, kind, target) VALUES (?,?,?)", (self.device(), str(body.get("kind", ""))[:16], str(body.get("target", ""))[:2000]))
                return self.j(200, {"ok": True})
            except Bad as e:
                return self.j(e.code, {"error": str(e)})
        if path != "/api/login":
            return self.j(404, {"error": "not found"})
        who = self.who()
        if throttled(_fails, who, FAIL_LIMIT, FAIL_WINDOW):
            return self.j(429, {"error": "too many attempts, try again later"})
        body = self.body(2048)
        given = str(body.get("secret", ""))
        if SECRET and hmac.compare_digest(hashlib.sha256(given.encode()).digest(), hashlib.sha256(SECRET.encode()).digest()):
            dev = re.sub(r"[^\w-]", "", str(body.get("device", "")))[:32]
            if dev:  # a named device is a native client: a year-long bearer token in the body, no cookie
                return self.j(200, {"ok": True, "token": make_cookie(dev, 365)})
            ck = f"nav={make_cookie()}; Max-Age={SESSION_DAYS * 86400}; Path=/; HttpOnly; Secure; SameSite=Strict"
            return self.j(200, {"ok": True}, extra=[("Set-Cookie", ck)])
        note(_fails, who)
        time.sleep(1)
        return self.j(401, {"error": "wrong passphrase"})


if __name__ == "__main__":
    if len(SECRET) < 16:
        raise SystemExit("NAV_SECRET must be set and at least 16 characters")
    if DB:
        init_db()
        threading.Thread(target=watch_loop, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
