"""Personal navigation web app: static PWA plus a small read-only JSON API over the local Nominatim and OpenTripPlanner.

Auth is one passphrase (NAV_SECRET) exchanged for a signed, HttpOnly cookie. The API never writes anything and takes no free-form GraphQL.
"""
import datetime
import hashlib
import hmac
import json
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
        out.append({"title": title, "sub": ", ".join(x for x in (road if road and road != title else "", place) if x), "lat": float(h["lat"]), "lon": float(h["lon"]), "kind": h.get("type")})
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
    dt = f'dateTime:{{{"latestArrival" if arrive else "earliestDeparture"}:"{when}"}}'
    if mode == "transit":
        picked = [TRANSIT[k] for k in one("transit", "rail,bus,tram").split(",") if k in TRANSIT]
        if not picked:
            raise Bad("pick at least one transit mode")
        modes = f'modes:{{transit:{{transit:[{",".join("{mode:" + m + "}" for m in picked)}]}}}}'
    else:
        modes, n = f"modes:{{directOnly:true,direct:[{DIRECT[mode]}]}}", 1  # a street search yields exactly one itinerary
    loc = lambda a, b: f"{{location:{{coordinate:{{latitude:{a},longitude:{b}}}}}}}"
    query = f"{{ planConnection(origin:{loc(la, lo)} destination:{loc(ta, to)} {dt} {modes} first:{n}) {{ edges {{ node {{ start end duration numberOfTransfers walkDistance {LEG} }} }} }} }}"
    edges = gql(query)["planConnection"]["edges"]
    return {"itineraries": [{"start": e["node"]["start"], "end": e["node"]["end"], "duration_s": round(e["node"]["duration"]),
                             "transfers": e["node"]["numberOfTransfers"], "walk_m": round(e["node"].get("walkDistance") or 0),
                             "legs": [leg_out(l) for l in e["node"]["legs"]]} for e in edges],
            "when": when, "by": "arrive" if arrive else "depart"}


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
    d = gql("query($id:String!,$d:String!){ trip(id:$id){ tripHeadsign route{ shortName color } stoptimesForDate(serviceDate:$d){ stop{ name } scheduledDeparture realtimeDeparture departureDelay realtime } } }", {"id": tid, "d": day})["trip"]
    if not d:
        raise Bad("unknown trip", 404)
    return {"line": d["route"]["shortName"], "color": d["route"].get("color"), "to": d["tripHeadsign"], "stops": [
        {"stop": s["stop"]["name"], "scheduled": hhmm(s["scheduledDeparture"]), **sane_rt(s["scheduledDeparture"], s["realtimeDeparture"], s["departureDelay"], s["realtime"])} for s in d["stoptimesForDate"]]}


def api_info(_q):
    try:
        m = json.load(open(MANIFEST))
    except (OSError, ValueError):
        m = {}
    return {"built_at": m.get("built_at"), "osm_data": m.get("osm_data_timestamp"), "feeds": [{"id": f["id"], "attribution": f.get("attribution")} for f in m.get("feeds", [])],
            "attribution": m.get("attribution", "© OpenStreetMap contributors")}


ROUTES = {"/api/geocode": api_geocode, "/api/reverse": api_reverse, "/api/plan": api_plan, "/api/nearby": api_nearby,
          "/api/departures": api_departures, "/api/trip": api_trip, "/api/info": api_info}


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
            CREATE TABLE IF NOT EXISTS pushes (device TEXT PRIMARY KEY, kind TEXT, target TEXT);""")


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
        self.send_header("Cache-Control", "no-store" if ctype == "application/json" else "no-cache")
        for k, v in extra:
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
            return self.j(200, {"ok": True})
        if u.path.startswith("/api/"):
            if u.path == "/api/session":
                return self.j(200 if self.authed() else 401, {"ok": self.authed()})
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
            who = self.who()
            if throttled(_hits, who, PER_MINUTE, 60):
                return self.j(429, {"error": "slow down"})
            note(_hits, who)
            try:
                return self.j(200, fn(urllib.parse.parse_qs(u.query)))
            except Bad as e:
                return self.j(e.code, {"error": str(e)})
            except Exception:
                return self.j(502, {"error": "upstream unavailable"})
        return self.static(u.path)

    def static(self, path):
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        full = os.path.realpath(os.path.join(STATIC, rel))
        if not full.startswith(os.path.realpath(STATIC) + os.sep) or not os.path.isfile(full):
            full = os.path.join(STATIC, "index.html")  # single page app: unknown paths fall back to the shell
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if full.endswith(".webmanifest"):
            ctype = "application/manifest+json"
        with open(full, "rb") as f:
            self.send(200, f.read(), ctype + ("; charset=utf-8" if ctype.startswith("text/") or "javascript" in ctype else ""))

    def body(self, limit=8192):
        try:
            return json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", "0")), limit)) or b"{}")
        except ValueError:
            return {}

    def do_DELETE(self):
        u = urllib.parse.urlparse(self.path)
        if u.path.replace("/api/v1/", "/api/") != "/api/watch" or not DB or not self.authed():
            return self.j(404 if self.authed() else 401, {"error": "not found"})
        wid = (urllib.parse.parse_qs(u.query).get("id") or [""])[0]
        with conn() as c:
            c.execute("DELETE FROM watches WHERE id=? AND device=?", (wid, self.device()))
        return self.j(200, {"ok": True})

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/api/v1/"):
            path = "/api/" + path[8:]
        if path == "/api/logout":
            return self.j(200, {"ok": True}, extra=[("Set-Cookie", "nav=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Strict")])
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
