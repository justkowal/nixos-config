"""Adds derived shapes to a GTFS zip whose trips have none, by routing stop to stop over the OSM rail or road network.

    derive_shapes.py in.zip out.zip scope.osm.pbf report.json

Needs `osmium` on PATH. Trips that already have a shape are left alone. Derived ids start with `derived-`.
A segment with no route (no snap, no path, or a detour over 2.5x the straight line) stays a straight line and is counted in the report.
"""
import csv
import hashlib
import heapq
import io
import json
import math
import subprocess
import sys
import tempfile
import zipfile
from collections import defaultdict

SNAP_M = {"rail": 400, "road": 150, "tram": 150}
DETOUR = 2.5
CELL = 0.005  # degrees, roughly 400 m


def mode_of(route_type):
    t = int(route_type or 3)
    if t == 2 or 100 <= t < 200:
        return "rail"
    if t == 0 or 900 <= t < 1000:
        return "tram"
    return "road"


def dist_m(a, b):
    dy = (b[1] - a[1]) * 111320.0
    dx = (b[0] - a[0]) * 111320.0 * math.cos(math.radians((a[1] + b[1]) / 2))
    return math.hypot(dx, dy)


def build_graph(features, mode):
    """features: GeoJSON line features with a properties dict. Nodes are (lon, lat) tuples, rounded to 1e-7."""
    adj = defaultdict(list)
    for f in features:
        g = f.get("geometry") or {}
        if g.get("type") != "LineString":
            continue
        p = f.get("properties") or {}
        one = 0
        if mode == "road":
            hw = p.get("highway")
            if hw in ("footway", "path", "cycleway", "steps", "pedestrian", "track", "service", "bridleway", "corridor"):
                continue
            if p.get("oneway") in ("yes", "1", "true") or p.get("junction") == "roundabout":
                one = 1
            elif p.get("oneway") == "-1":
                one = -1
        else:
            if p.get("service") in ("yard", "siding", "spur"):
                continue
        pts = [(round(x, 7), round(y, 7)) for x, y in g["coordinates"]]
        for a, b in zip(pts, pts[1:]):
            if a == b:
                continue
            d = dist_m(a, b)
            if one >= 0:
                adj[a].append((b, d))
            if one <= 0:
                adj[b].append((a, d))
    return adj


class Index:
    def __init__(self, nodes):
        self.cells = defaultdict(list)
        for n in nodes:
            self.cells[(int(n[0] / CELL), int(n[1] / CELL))].append(n)

    def nearest(self, pt, limit):
        cx, cy = int(pt[0] / CELL), int(pt[1] / CELL)
        best, bd = None, limit
        rings = int(limit / 400) + 2
        for dx in range(-rings, rings + 1):
            for dy in range(-rings, rings + 1):
                for n in self.cells.get((cx + dx, cy + dy), ()):
                    d = dist_m(pt, n)
                    if d < bd:
                        best, bd = n, d
        return best


def astar(adj, src, dst, cap):
    h = lambda n: dist_m(n, dst)
    pq = [(h(src), 0.0, src)]
    best = {src: 0.0}
    prev = {}
    while pq:
        _, g, n = heapq.heappop(pq)
        if n == dst:
            path = [n]
            while n in prev:
                n = prev[n]
                path.append(n)
            return path[::-1], g
        if g > best.get(n, 1e18) or g > cap:
            continue
        for m, d in adj.get(n, ()):
            ng = g + d
            if ng < best.get(m, 1e18):
                best[m] = ng
                prev[m] = n
                heapq.heappush(pq, (ng + h(m), ng, m))
    return None, 0.0


def route_segment(adj, idx, a, b, mode):
    straight = dist_m(a, b)
    na, nb = idx.nearest(a, SNAP_M[mode]), idx.nearest(b, SNAP_M[mode])
    if na is None or nb is None:
        return None
    if na == nb:
        return [a, b]
    path, length = astar(adj, na, nb, straight * DETOUR + 500)
    if path is None or length > straight * DETOUR + 500:
        return None
    return [a] + path + [b]


def read_csv(z, name):
    if name not in z.namelist():
        return None
    return list(csv.DictReader(io.TextIOWrapper(z.open(name), encoding="utf-8-sig")))


def write_csv(rows, fields):
    out = io.StringIO()
    w = csv.DictWriter(out, fieldnames=fields, lineterminator="\n")
    w.writeheader()
    w.writerows(rows)
    return out.getvalue().encode()


def osm_lines(pbf, mode, bbox):
    flt = {"rail": "w/railway=rail", "tram": "w/railway=tram", "road": "w/highway"}[mode]
    with tempfile.TemporaryDirectory() as t:
        subprocess.run(["osmium", "extract", "-O", "-b", ",".join(f"{v:.5f}" for v in bbox), "-s", "simple", "-o", f"{t}/b.pbf", pbf], check=True, capture_output=True)
        subprocess.run(["osmium", "tags-filter", "-O", "-o", f"{t}/f.pbf", f"{t}/b.pbf", flt], check=True, capture_output=True)
        subprocess.run(["osmium", "export", "-O", "-f", "geojsonseq", "--geometry-types=linestring", "-o", f"{t}/f.geojsonseq", f"{t}/f.pbf"], check=True, capture_output=True)
        out = []
        for line in open(f"{t}/f.geojsonseq", encoding="utf-8"):
            line = line.strip().lstrip("\x1e")
            if line:
                out.append(json.loads(line))
    return out


def derive(zin, zout, pbf, report_path, lines_for=osm_lines):
    z = zipfile.ZipFile(zin)
    trips, routes, stops = read_csv(z, "trips.txt"), read_csv(z, "routes.txt"), read_csv(z, "stops.txt")
    old_shapes = read_csv(z, "shapes.txt") or []
    rtype = {r["route_id"]: mode_of(r.get("route_type")) for r in routes}
    loc = {s["stop_id"]: (float(s["stop_lon"]), float(s["stop_lat"])) for s in stops if s.get("stop_lat") and s.get("stop_lon")}

    seq = defaultdict(list)
    for r in read_csv(z, "stop_times.txt") or []:
        seq[r["trip_id"]].append((int(r["stop_sequence"]), r["stop_id"]))
    todo = [t for t in trips if not t.get("shape_id")]
    if not todo:
        json.dump({"trips_without_shape": 0}, open(report_path, "w"))
        return None
    patterns = defaultdict(list)
    for t in todo:
        stops_ = tuple(s for _, s in sorted(seq.get(t["trip_id"], [])))
        if len(stops_) >= 2 and all(s in loc for s in stops_):
            patterns[(rtype[t["route_id"]], stops_)].append(t)

    rep = {"trips_without_shape": len(todo), "patterns": len(patterns), "derived": 0, "partial": 0, "straight_segments": 0, "routed_segments": 0, "skipped_trips": len(todo) - sum(len(v) for v in patterns.values())}
    new_rows, graphs, cache = [], {}, {}
    for mode in sorted({m for m, _ in patterns}):
        pts = [loc[s] for (m, st) in patterns if m == mode for s in st]
        bbox = (min(p[0] for p in pts) - 0.05, min(p[1] for p in pts) - 0.05, max(p[0] for p in pts) + 0.05, max(p[1] for p in pts) + 0.05)
        adj = build_graph(lines_for(pbf, mode, bbox), mode)
        graphs[mode] = (adj, Index(adj.keys()))
    for (mode, st), ts in sorted(patterns.items(), key=lambda kv: kv[0][1]):
        adj, idx = graphs[mode]
        line, bad = [], 0
        for a, b in zip(st, st[1:]):
            k = (mode, a, b)
            if k not in cache:
                cache[k] = route_segment(adj, idx, loc[a], loc[b], mode)
            seg = cache[k]
            if seg is None:
                bad += 1
                rep["straight_segments"] += 1
                seg = [loc[a], loc[b]]
            else:
                rep["routed_segments"] += 1
            line.extend(seg if not line else seg[1:])
        sid = "derived-" + hashlib.sha1(("|".join(st) + mode).encode()).hexdigest()[:12]
        for i, (x, y) in enumerate(line):
            new_rows.append({"shape_id": sid, "shape_pt_lat": f"{y:.6f}", "shape_pt_lon": f"{x:.6f}", "shape_pt_sequence": i})
        for t in ts:
            t["shape_id"] = sid
        rep["derived"] += 1
        rep["partial"] += bool(bad)

    fields = list(trips[0].keys())
    if "shape_id" not in fields:
        fields.append("shape_id")
    shape_fields = ["shape_id", "shape_pt_lat", "shape_pt_lon", "shape_pt_sequence"]
    kept = [{k: r.get(k, "") for k in shape_fields} for r in old_shapes]
    with zipfile.ZipFile(zout, "w", zipfile.ZIP_DEFLATED) as out:
        for n in z.namelist():
            if n in ("trips.txt", "shapes.txt"):
                continue
            out.writestr(n, z.read(n))
        out.writestr("trips.txt", write_csv(trips, fields))
        if kept or new_rows:
            out.writestr("shapes.txt", write_csv(kept + new_rows, shape_fields))
    json.dump(rep, open(report_path, "w"), indent=1)
    return rep


if __name__ == "__main__":
    r = derive(*sys.argv[1:5])
    print(json.dumps(r))
    sys.exit(0 if r else 3)  # 3: every trip already has a shape, no output written
