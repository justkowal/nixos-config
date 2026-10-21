"""Reconcile stop positions: operator map markers (primary) against kiedyPrzyjedzie stops, matched by name."""
import math
from collections import defaultdict

from opsite import norm


def metres(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 12742000 * math.asin(math.sqrt(h))


def by_name(kp_stops):
    out = defaultdict(list)
    for pid, s in kp_stops.items():
        out[norm(s["name"])].append((pid, s))
    return out


def nearest_kp(op, names):
    """(distance_m, kp place id) of the closest kiedyPrzyjedzie post with the same name, or None."""
    best = None
    for pid, s in names.get(norm(op["name"]), []):
        d = metres((op["lat"], op["lon"]), (s["lat"], s["lon"]))
        if best is None or d < best[0]:
            best = (d, pid)
    return best


def compare(op_stops, kp_stops):
    """op_stops: {op_id: {name, lat, lon}}. Returns counts and the stops that need a human look."""
    names = by_name(kp_stops)
    r = {"op_stops": len(op_stops), "within_30m": 0, "30_to_100m": 0, "over_100m": [], "op_only": [], "kp_names_without_op": []}
    seen = set()
    for oid, o in sorted(op_stops.items(), key=lambda x: str(x[0])):
        n = nearest_kp(o, names)
        if n is None:
            r["op_only"].append({"op_id": oid, "name": o["name"]})
            continue
        seen.add(norm(o["name"]))
        if n[0] <= 30:
            r["within_30m"] += 1
        elif n[0] <= 100:
            r["30_to_100m"] += 1
        else:
            r["over_100m"].append({"op_id": oid, "name": o["name"], "kp_place": n[1], "metres": round(n[0])})
    r["kp_names_without_op"] = sorted({s["name"] for s in kp_stops.values() if norm(s["name"]) not in seen})
    return r
