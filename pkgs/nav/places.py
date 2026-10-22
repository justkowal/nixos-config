"""General map places for the navigation app, from open data only.

- search by category and place cards: the local Nominatim database (OpenStreetMap, ODbL)
- descriptions and photos: Wikipedia and Wikidata/Wikimedia Commons (CC BY-SA), fetched by the server, cached
- reviews: Mangrove Reviews (open, CC BY) where they exist, plus private notes stored on this server
Nothing here talks to Google, Yelp or any other proprietary review source.
"""
import datetime
import json
import math
import os
import re
import threading
import time
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

import hours

TZ = ZoneInfo("Europe/Warsaw")
PGHOST = os.environ.get("NOMINATIM_PGHOST", "mcp-nominatim")
UA = f"kowal-lab-nav/0.1 (personal use; contact {os.environ.get('FEED_CONTACT', 'unset')})"

CATS = {
    "food": ("Food", [("amenity", ["restaurant", "fast_food", "food_court"])]),
    "cafe": ("Cafes", [("amenity", ["cafe", "ice_cream"])]),
    "bar": ("Bars", [("amenity", ["bar", "pub", "biergarten"])]),
    "groceries": ("Groceries", [("shop", ["supermarket", "convenience", "greengrocer", "bakery", "butcher"])]),
    "pharmacy": ("Pharmacies", [("amenity", ["pharmacy"])]),
    "health": ("Health", [("amenity", ["hospital", "clinic", "doctors", "dentist"])]),
    "fuel": ("Fuel and charging", [("amenity", ["fuel", "charging_station"])]),
    "atm": ("ATMs and banks", [("amenity", ["atm", "bank"])]),
    "parking": ("Parking", [("amenity", ["parking"])]),
    "toilets": ("Toilets", [("amenity", ["toilets"])]),
    "hotels": ("Hotels", [("tourism", ["hotel", "hostel", "guest_house", "apartment", "motel"])]),
    "sights": ("Sights", [("tourism", ["attraction", "museum", "gallery", "viewpoint", "zoo"]), ("historic", None)]),
    "parks": ("Parks", [("leisure", ["park", "playground", "garden", "nature_reserve"])]),
    "shops": ("Shops", [("shop", None)]),
}
MAIN_CLASSES = ("amenity", "shop", "tourism", "leisure", "historic", "office", "craft", "healthcare", "building", "man_made", "natural", "railway", "highway", "place")
PRETTY = {"fast_food": "Fast food", "guest_house": "Guest house", "charging_station": "Charging station", "atm": "ATM", "doctors": "Doctor", "ice_cream": "Ice cream",
          "food_court": "Food court", "biergarten": "Beer garden", "nature_reserve": "Nature reserve", "convenience": "Convenience store"}
OSM_ID = re.compile(r"([NWR])(\d{1,12})")
LANG = re.compile(r"[a-z]{2,3}")


def label(klass, typ):
    typ = typ or klass
    return PRETTY.get(typ) or typ.replace("_", " ").capitalize()


def _db():
    import pg8000.native
    return pg8000.native.Connection(user="osmro", host=PGHOST, database="nominatim", port=int(os.environ.get("NOMINATIM_PGPORT", "5432")), timeout=10)


def hav(a_lat, a_lon, b_lat, b_lon):
    p = math.pi / 180
    a = math.sin((b_lat - a_lat) * p / 2) ** 2 + math.cos(a_lat * p) * math.cos(b_lat * p) * math.sin((b_lon - a_lon) * p / 2) ** 2
    return 12742000 * math.asin(math.sqrt(a))


def _now():
    return datetime.datetime.now(TZ)


def _row_card(row, lat=None, lon=None):
    osm_type, osm_id, klass, typ, name, x, y, hrs = row[:8]
    st = hours.state(hrs, _now())
    c = {"id": f"{osm_type}{osm_id}", "title": name, "cat": label(klass, typ), "lat": round(y, 6), "lon": round(x, 6), "open": st["open"]}
    if lat is not None:
        c["dist_m"] = round(hav(lat, lon, y, x))
    return c


NEARBY_CLASSES = ["amenity", "shop", "tourism", "leisure", "historic"]
EXCLUDE_TYPES = ("bench", "waste_basket", "recycling", "post_box", "vending_machine", "telephone", "waste_disposal", "grit_bin", "shelter")


def explore(cat, lat, lon, radius=800):
    """places around a point, nearest first. If cat is None, 'all' or 'nearby', returns all nearby POIs."""
    radius = max(100, min(int(radius), 3000))
    dy, dx = radius / 110540, radius / (111320 * math.cos(math.radians(lat)))
    box = {"x1": lon - dx, "y1": lat - dy, "x2": lon + dx, "y2": lat + dy}
    out = []
    conn = _db()
    try:
        if not cat or cat in ("all", "nearby"):
            category_name = "Nearby"
            params = dict(box, cls=NEARBY_CLASSES)
            rows = conn.run(
                "SELECT osm_type, osm_id, class, type, name->'name', ST_X(centroid), ST_Y(centroid), extratags->'opening_hours' FROM placex "
                "WHERE class = ANY(:cls) AND name ? 'name' AND geometry && ST_MakeEnvelope(:x1, :y1, :x2, :y2, 4326) "
                "AND (type IS NULL OR type NOT IN ('bench', 'waste_basket', 'recycling', 'post_box', 'vending_machine', 'telephone', 'waste_disposal', 'grit_bin', 'shelter')) "
                "LIMIT 250", **params)
            out = [_row_card(r, lat, lon) for r in rows]
        elif cat in CATS:
            category_name = CATS[cat][0]
            for klass, types in CATS[cat][1]:
                tcond = "AND type = ANY(:tlist)" if types else "AND type IS NOT NULL"
                params = dict(box, k=klass)
                if types:
                    params["tlist"] = types
                rows = conn.run(
                    "SELECT osm_type, osm_id, class, type, name->'name', ST_X(centroid), ST_Y(centroid), extratags->'opening_hours' FROM placex "
                    f"WHERE class = :k {tcond} AND name ? 'name' AND geometry && ST_MakeEnvelope(:x1, :y1, :x2, :y2, 4326) LIMIT 120", **params)
                out += [_row_card(r, lat, lon) for r in rows]
        else:
            raise ValueError("unknown category")
    finally:
        conn.close()

    seen = set()
    dedup = []
    for c in out:
        if c["id"] not in seen:
            seen.add(c["id"])
            dedup.append(c)
    out = [c for c in dedup if c["dist_m"] <= radius]
    out.sort(key=lambda c: c["dist_m"])
    return {"category": category_name, "places": out[:80]}



def _parse_tags(js):
    try:
        return json.loads(js) if js else {}
    except ValueError:
        return {}


def place_row(osm=None, lat=None, lon=None, name=None):
    if osm and not OSM_ID.fullmatch(osm):
        raise ValueError("bad place id")
    conn = _db()
    try:
        cols = ("osm_type, osm_id, class, type, name->'name', ST_X(centroid), ST_Y(centroid), extratags->'opening_hours', "
                "hstore_to_json(coalesce(extratags, ''::hstore))::text, hstore_to_json(coalesce(address, ''::hstore))::text, name->'name:en', name->'name:pl'")
        if osm:
            m = OSM_ID.fullmatch(osm)
            if not m:
                raise ValueError("bad place id")
            rows = conn.run(f"SELECT {cols} FROM placex WHERE osm_type = :t AND osm_id = :i AND name ? 'name' ORDER BY rank_search LIMIT 1", t=m[1], i=int(m[2]))
        else:
            d = 0.0004
            cond = "AND lower(name->'name') = lower(:n)" if name else "AND class = ANY(:cls)"
            params = {"x1": lon - 2 * d, "y1": lat - d, "x2": lon + 2 * d, "y2": lat + d, "lon": lon, "lat": lat}
            if name:
                params["n"] = name
            else:
                params["cls"] = ["amenity", "shop", "tourism", "leisure", "historic", "office", "craft"]
            rows = conn.run(f"SELECT {cols} FROM placex WHERE name ? 'name' {cond} AND geometry && ST_MakeEnvelope(:x1, :y1, :x2, :y2, 4326) "
                            "ORDER BY centroid <-> ST_SetSRID(ST_MakePoint(:lon, :lat), 4326) LIMIT 1", **params)
        return rows[0] if rows else None
    finally:
        conn.close()


def _safe_url(u):
    if not u:
        return None
    u = u.strip()
    if not re.match(r"^https?://", u, re.I):
        u = "https://" + u if re.match(r"^[\w.-]+\.[a-z]{2,}(/|$)", u, re.I) else None
    return u if u and len(u) < 300 else None


def _addr(a):
    street = " ".join(x for x in (a.get("addr:street") or a.get("street"), a.get("addr:housenumber") or a.get("housenumber")) if x)
    city = " ".join(x for x in (a.get("addr:postcode") or a.get("postcode"), a.get("addr:city") or a.get("city")) if x)
    return ", ".join(x for x in (street, city) if x)


YES = {"yes", "true", "1"}


def _attrs(t):
    out = []
    w = t.get("wheelchair")
    if w:
        out.append({"yes": "Wheelchair accessible", "limited": "Partly wheelchair accessible", "no": "Not wheelchair accessible"}.get(w))
    if t.get("cuisine"):
        out.append("Cuisine: " + ", ".join(x.strip().replace("_", " ") for x in t["cuisine"].split(";")[:4]))
    flags = [("takeaway", "Takeaway"), ("delivery", "Delivery"), ("outdoor_seating", "Outdoor seating"), ("internet_access", "Wi-Fi"), ("air_conditioning", "Air conditioning"),
             ("payment:cards", "Cards accepted"), ("payment:contactless", "Contactless"), ("drive_through", "Drive through"), ("dog", "Dogs allowed"), ("toilets", "Toilets"), ("wheelchair:description", None)]
    for k, text in flags:
        v = t.get(k)
        if text and v and (v in YES or (k == "internet_access" and v in ("wlan", "wifi")) or (k == "takeaway" and v == "only")):
            out.append(text)
    for diet, text in (("diet:vegetarian", "Vegetarian options"), ("diet:vegan", "Vegan options"), ("diet:gluten_free", "Gluten-free options"), ("diet:halal", "Halal"), ("diet:kosher", "Kosher")):
        if t.get(diet) in ("yes", "only"):
            out.append(text)
    if t.get("stars"):
        out.append(f"{t['stars']} stars")
    if t.get("capacity") and t.get("amenity") == "parking":
        out.append(f"{t['capacity']} spaces")
    if t.get("fee"):
        out.append("Paid" if t["fee"] in YES else "Free" if t["fee"] == "no" else "")
    if t.get("brand") or t.get("operator"):
        out.append("Operator: " + (t.get("brand") or t.get("operator")))
    return [x for x in out if x]


def place_card(osm=None, lat=None, lon=None, name=None):
    row = place_row(osm, lat, lon, name)
    if not row:
        return None
    osm_type, osm_id, klass, typ, title, x, y, hrs, tags_js, addr_js, name_en, name_pl = row
    tags, addr = _parse_tags(tags_js), _parse_tags(addr_js)
    st = hours.state(hrs, _now())
    kind = {"N": "node", "W": "way", "R": "relation"}[osm_type]
    return {"id": f"{osm_type}{osm_id}", "title": name_pl or title, "cat": label(klass, typ), "class": klass, "type": typ, "lat": round(y, 6), "lon": round(x, 6),
            "address": _addr(addr), "phone": tags.get("phone") or tags.get("contact:phone"), "email": tags.get("email") or tags.get("contact:email"),
            "website": _safe_url(tags.get("website") or tags.get("contact:website") or tags.get("url")),
            "hours": {"raw": hrs, **st}, "attributes": _attrs(dict(tags, amenity=klass == "amenity" and typ or None)),
            "wikipedia": tags.get("wikipedia"), "wikidata": tags.get("wikidata"), "osm_description": tags.get("description:pl") or tags.get("description"),
            "osm_url": f"https://www.openstreetmap.org/{kind}/{osm_id}"}


# ---------------------------------------------------------------- open data from the web, cached
_cache = {}
_cache_lock = threading.Lock()


def _cached(key, ttl, fn):
    now = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
    try:
        val = fn()
    except Exception:
        val = None
    with _cache_lock:
        if len(_cache) > 600:
            for k in sorted(_cache, key=lambda x: _cache[x][0])[:150]:
                _cache.pop(k, None)
        _cache[key] = (now, val)
    return val


def _get_json(url, timeout=6):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def wiki_summary(tag):
    """tag 'pl:Title' -> {text, url, thumb, desc, source}"""
    m = re.fullmatch(r"([a-z]{2,3}):(.{1,200})", tag or "")
    if not m or not LANG.fullmatch(m[1]):
        return None

    def go():
        j = _get_json(f"https://{m[1]}.wikipedia.org/api/rest_v1/page/summary/" + urllib.parse.quote(m[2].replace(" ", "_"), safe=""))
        if j.get("type") == "disambiguation" or not j.get("extract"):
            return None
        return {"text": j["extract"], "desc": j.get("description"), "url": (j.get("content_urls") or {}).get("desktop", {}).get("page"),
                "thumb": (j.get("thumbnail") or {}).get("source"), "source": f"Wikipedia ({m[1]})", "license": "CC BY-SA"}
    return _cached(("wiki", tag), 86400, go)


def wikidata(qid):
    """Q-id -> {desc, wikipedia: 'pl:Title'|None, image: file name|None}"""
    if not re.fullmatch(r"Q\d{1,12}", qid or ""):
        return None

    def go():
        j = _get_json(f"https://www.wikidata.org/w/api.php?action=wbgetentities&ids={qid}&props=descriptions|sitelinks|claims&languages=pl|en&sitefilter=plwiki|enwiki&format=json")
        e = (j.get("entities") or {}).get(qid) or {}
        d = e.get("descriptions") or {}
        links = e.get("sitelinks") or {}
        wp = ("pl:" + links["plwiki"]["title"]) if "plwiki" in links else ("en:" + links["enwiki"]["title"]) if "enwiki" in links else None
        p18 = ((e.get("claims") or {}).get("P18") or [{}])[0].get("mainsnak", {}).get("datavalue", {}).get("value")
        return {"desc": (d.get("pl") or d.get("en") or {}).get("value"), "wikipedia": wp, "image": p18}
    return _cached(("wd", qid), 86400, go)


def commons_thumb(file_name):
    return "https://commons.wikimedia.org/wiki/Special:FilePath/" + urllib.parse.quote(file_name.replace(" ", "_"), safe="") + "?width=640" if file_name else None


def mangrove(lat, lon, name):
    """open reviews for a place, if any: {count, average, reviews:[{rating,text,date}]}"""
    def go():
        sub = f"geo:{lat:.5f},{lon:.5f}" + (f"?q={urllib.parse.quote(name)}" if name else "")
        j = _get_json("https://api.mangrove.reviews/reviews?" + urllib.parse.urlencode({"q": sub}), timeout=5)
        out = []
        for r in (j.get("reviews") or [])[:20]:
            p = r.get("payload") or r
            if p.get("rating") is None:
                continue
            out.append({"rating": round(p["rating"] / 20, 1), "text": (p.get("opinion") or "")[:600], "date": datetime.datetime.fromtimestamp(p.get("iat", 0), TZ).strftime("%Y-%m-%d") if p.get("iat") else ""})
        return {"count": len(out), "average": round(sum(x["rating"] for x in out) / len(out), 1) if out else None, "reviews": out}
    return _cached(("mg", round(lat, 4), round(lon, 4), name), 3600, go) or {"count": 0, "average": None, "reviews": []}


def more(card):
    """description, photo and open reviews for a card; every source is optional and failures just leave a field empty"""
    out = {"description": None, "photo": None, "reviews": None}
    reviews = {}
    t = threading.Thread(target=lambda: reviews.update(r=mangrove(card["lat"], card["lon"], card["title"])))
    t.start()  # the open reviews do not depend on Wikipedia, so they are fetched at the same time
    wp = card.get("wikipedia")
    wd = wikidata(card["wikidata"]) if card.get("wikidata") else None
    if not wp and wd:
        wp = wd["wikipedia"]
    s = wiki_summary(wp) if wp else None
    if s:
        out["description"] = {k: s[k] for k in ("text", "url", "source", "license")}
        if s.get("thumb"):
            out["photo"] = s["thumb"]
    if not out["description"]:
        text = card.get("osm_description") or (wd or {}).get("desc")
        if text:
            out["description"] = {"text": text, "url": None, "source": "OpenStreetMap" if card.get("osm_description") else "Wikidata", "license": "ODbL" if card.get("osm_description") else "CC0"}
    if not out["photo"] and wd and wd.get("image"):
        out["photo"] = commons_thumb(wd["image"])
    t.join(8)
    out["reviews"] = reviews.get("r") or {"count": 0, "average": None, "reviews": []}
    return out


# ---------------------------------------------------------------- image proxy (the browser never talks to Wikimedia)
IMG_HOSTS = {"upload.wikimedia.org", "commons.wikimedia.org", "thumb.wikimedia.org"}


def fetch_image(url):
    for _ in range(4):
        p = urllib.parse.urlsplit(url)
        if p.scheme != "https" or p.hostname not in IMG_HOSTS or p.username or p.port not in (None, 443):
            raise ValueError("image host not allowed")
        hit = _cached(("img", url), 86400, lambda u=url: _download(u))
        if isinstance(hit, tuple) and hit[0] == "redirect":
            url = hit[1]
            continue
        if not hit:
            raise ValueError("no image")
        return hit
    raise ValueError("too many redirects")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def _download(url):
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        r = opener.open(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=8)
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 303, 307, 308) and e.headers.get("Location"):
            return ("redirect", urllib.parse.urljoin(url, e.headers["Location"]))
        raise
    ctype = r.headers.get("Content-Type", "")
    if not ctype.startswith("image/"):
        raise ValueError("not an image")
    data = r.read(1_500_001)
    if len(data) > 1_500_000:
        raise ValueError("image too large")
    return (ctype, data)
