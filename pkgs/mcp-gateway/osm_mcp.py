"""Local OpenStreetMap MCP: Nominatim over HTTP plus read-only SQL on its database. Nothing here talks to a public OSM service."""
import json
import math
import os
import re
import threading
import time
import urllib.parse
import urllib.request

import pg8000.native

from stdio_mcp import obj, serve

NOM = os.environ.get("NOMINATIM_URL", "http://mcp-nominatim:8080")
PGHOST = os.environ.get("NOMINATIM_PGHOST", "mcp-nominatim")
MANIFEST = os.environ.get("GRAPH_MANIFEST", "/maps/graph/manifest.json")
ATTRIBUTION = "© OpenStreetMap contributors (ODbL)"
MAX_RESULTS = 50
MAX_CHARS = 30000
MAX_RADIUS_M = 5000
MAX_BBOX_DEG = 0.25
PER_MINUTE = int(os.environ.get("OSM_PER_MINUTE", "60"))
KEY = re.compile(r"^[a-z_:]{1,40}$")
calls, lock = [], threading.Lock()


def budget():
    with lock:
        now = time.time()
        calls[:] = [t for t in calls if t > now - 60]
        if len(calls) >= PER_MINUTE:
            raise RuntimeError(f"rate limit of {PER_MINUTE} osm calls per minute reached")
        calls.append(now)


def nominatim(path, **params):
    budget()
    url = f"{NOM}/{path}?" + urllib.parse.urlencode({**params, "accept-language": "pl,en"})
    with urllib.request.urlopen(url, timeout=15) as r:
        return json.load(r)


def db():
    return pg8000.native.Connection(user="osmro", host=PGHOST, database="nominatim", port=5432, timeout=10)


def cap(fc):
    """cut the feature list until the serialized result fits the output cap."""
    fc["attribution"] = ATTRIBUTION
    while len(json.dumps(fc, ensure_ascii=False)) > MAX_CHARS and fc["features"]:
        fc["features"].pop()
        fc["truncated"] = True
    return fc


def feature(row):
    osm_type, osm_id, cls, typ, name, lon, lat, dist = row
    return {"type": "Feature", "geometry": {"type": "Point", "coordinates": [round(lon, 6), round(lat, 6)]},
            "properties": {"osm": f"{osm_type}{osm_id}", "key": cls, "value": typ, "name": name,
                           **({"distance_m": int(dist)} if dist is not None else {})}}


def check_key(k, what):
    if not isinstance(k, str) or not KEY.match(k):
        raise RuntimeError(f"{what} must be a plain OSM tag key or value such as amenity or pharmacy")
    return k


def num(a, name, lo, hi):
    try:
        v = float(a[name])
    except (KeyError, TypeError, ValueError):
        raise RuntimeError(f"{name} is required and must be a number")
    if not lo <= v <= hi:
        raise RuntimeError(f"{name} must be between {lo} and {hi}")
    return v


def t_geocode(a):
    q = str(a.get("query", "")).strip()
    if not q:
        raise RuntimeError("query is required")
    r = nominatim("search", q=q, format="geojson", limit=min(int(a.get("limit", 5)), 10), addressdetails=0, countrycodes="pl,cz,sk")
    feats = [{"type": "Feature", "geometry": f["geometry"],
              "properties": {"name": f["properties"].get("display_name"), "key": f["properties"].get("category"),
                             "value": f["properties"].get("type"), "osm": f"{f['properties'].get('osm_type', '?')[:1].upper()}{f['properties'].get('osm_id')}"}}
             for f in r.get("features", [])]
    return cap({"type": "FeatureCollection", "features": feats})


def t_reverse(a):
    lat, lon = num(a, "lat", 48, 52), num(a, "lon", 16, 24)
    r = nominatim("reverse", lat=lat, lon=lon, format="geojson", zoom=min(int(a.get("zoom", 18)), 18))
    feats = [{"type": "Feature", "geometry": f["geometry"],
              "properties": {"name": f["properties"].get("display_name"), "key": f["properties"].get("category"),
                             "value": f["properties"].get("type")}} for f in r.get("features", [])]
    return cap({"type": "FeatureCollection", "features": feats})


def t_element(a):
    t, i = str(a.get("osm_type", "")).upper()[:1], str(a.get("osm_id", ""))
    if t not in ("N", "W", "R") or not i.isdigit():
        raise RuntimeError("osm_type must be node, way or relation and osm_id a number")
    r = nominatim("lookup", osm_ids=f"{t}{i}", format="geojson", extratags=1, namedetails=1)
    return cap({"type": "FeatureCollection", "features": r.get("features", [])})


def search_rows(where, params, limit, dist_sql="NULL"):
    limit = max(1, min(int(limit or 20), MAX_RESULTS))
    con = db()
    try:
        rows = con.run(
            f"SELECT osm_type, osm_id, class, type, name->'name', ST_X(centroid), ST_Y(centroid), {dist_sql} AS d "
            f"FROM placex WHERE {where} ORDER BY d NULLS LAST, osm_id LIMIT {limit}", **params)
    finally:
        con.close()
    return cap({"type": "FeatureCollection", "features": [feature(r) for r in rows]})


def name_filter(a, params):
    if a.get("name_contains"):
        params["nm"] = "%" + str(a["name_contains"])[:60] + "%"
        return " AND (name->'name') ILIKE :nm"
    return ""


def t_nearby(a):
    budget()
    lat, lon = num(a, "lat", 48, 52), num(a, "lon", 16, 24)
    radius = num({"r": a.get("radius_m", 500)}, "r", 10, MAX_RADIUS_M)
    key = check_key(a.get("key", "amenity"), "key")
    p = {"lat": lat, "lon": lon, "r": radius, "k": key}
    dlat, dlon = radius / 111320.0, radius / (111320.0 * math.cos(math.radians(lat)))
    p.update(x1=lon - dlon, x2=lon + dlon, y1=lat - dlat, y2=lat + dlat)
    where = "class = :k AND centroid && ST_MakeEnvelope(:x1, :y1, :x2, :y2, 4326) AND ST_DWithin(centroid::geography, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography, :r)"
    if a.get("value"):
        p["v"] = check_key(a["value"], "value")
        where += " AND type = :v"
    where += name_filter(a, p)
    return search_rows(where, p, a.get("limit"), "ST_Distance(centroid::geography, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography)")


def t_query(a):
    budget()
    bb = a.get("bbox")
    if not (isinstance(bb, list) and len(bb) == 4):
        raise RuntimeError("bbox must be [west, south, east, north]")
    w, s, e, n = (float(x) for x in bb)
    if not (e > w and n > s) or e - w > MAX_BBOX_DEG or n - s > MAX_BBOX_DEG:
        raise RuntimeError(f"bbox must be at most {MAX_BBOX_DEG} degrees wide and high (about 28 km by 18 km)")
    p = {"k": check_key(a.get("key"), "key"), "x1": w, "y1": s, "x2": e, "y2": n}
    where = "class = :k AND centroid && ST_MakeEnvelope(:x1, :y1, :x2, :y2, 4326)"
    if a.get("value"):
        p["v"] = check_key(a["value"], "value")
        where += " AND type = :v"
    where += name_filter(a, p)
    return search_rows(where, p, a.get("limit"))


def t_info(_a):
    out = {"attribution": ATTRIBUTION, "license": "ODbL 1.0", "scope": "Silesian and Lesser Poland voivodeships plus 10 km buffer"}
    try:
        out["nominatim"] = nominatim("status", format="json")
    except Exception as e:
        out["nominatim"] = f"unreachable: {e}"
    try:
        with open(MANIFEST) as f:
            m = json.load(f)
        out["extract"] = {k: m.get(k) for k in ("osm_data_timestamp", "osm_source", "built_at")}
    except OSError:
        out["extract"] = "no manifest"
    out["public_services_used"] = False
    return out


P = {"lat": {"type": "number"}, "lon": {"type": "number"}}
TAG = {"key": {"type": "string", "description": "OSM tag key, e.g. amenity, shop, tourism"},
       "value": {"type": "string", "description": "tag value, e.g. pharmacy"},
       "name_contains": {"type": "string"}, "limit": {"type": "integer", "description": f"at most {MAX_RESULTS}"}}
TOOLS = {
    "osm_geocode": dict(desc="Geocode a place name or address with the local Nominatim. Returns GeoJSON.", ro=True, **{"class": "read"},
                        schema=obj({"query": {"type": "string"}, "limit": {"type": "integer"}}, ["query"]), fn=t_geocode),
    "osm_reverse_geocode": dict(desc="Nearest address or place for a coordinate. Returns GeoJSON.", ro=True, **{"class": "read"},
                                schema=obj({**P, "zoom": {"type": "integer"}}, ["lat", "lon"]), fn=t_reverse),
    "osm_nearby": dict(desc=f"Features with an OSM tag within a radius of a point (up to {MAX_RADIUS_M} m), nearest first. Returns GeoJSON.",
                       ro=True, **{"class": "read"},
                       schema=obj({**P, "radius_m": {"type": "number"}, **TAG}, ["lat", "lon"]), fn=t_nearby),
    "osm_query": dict(desc=f"Features with an OSM tag inside a bounding box (at most {MAX_BBOX_DEG} degrees each way). Returns GeoJSON.",
                      ro=True, **{"class": "read"},
                      schema=obj({"bbox": {"type": "array", "items": {"type": "number"}, "description": "west, south, east, north"}, **TAG}, ["bbox", "key"]),
                      fn=t_query),
    "osm_get_element": dict(desc="Fetch one OSM node, way or relation by id. Returns GeoJSON with extra tags.", ro=True, **{"class": "read"},
                            schema=obj({"osm_type": {"type": "string", "enum": ["node", "way", "relation"]}, "osm_id": {"type": "string"}}, ["osm_type", "osm_id"]),
                            fn=t_element),
    "osm_data_info": dict(desc="Data extract date, scope, license and attribution of the local OSM data.", ro=True, **{"class": "read"},
                          schema=obj(), fn=t_info),
}


if __name__ == "__main__":
    serve("osm", TOOLS)
