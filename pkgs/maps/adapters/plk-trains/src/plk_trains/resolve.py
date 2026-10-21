"""Turns configured station and carrier names into API IDs, once, cached on disk."""
import hashlib
import json
import logging
import os
import time

log = logging.getLogger("plk.resolve")
MAX_AGE_S = 90 * 86400


def norm(s):
    return " ".join(str(s).casefold().split())


def _fingerprint(corridor):
    return hashlib.sha256(json.dumps(corridor, sort_keys=True).encode()).hexdigest()[:16]


def _all_stations(client):
    out, page = {}, 1
    while True:
        data, _ = client.get("/api/v1/dictionaries/stations", {"page": page, "pageSize": 5000},
                             "StationsResponse", prio="static")
        for s in data["stations"] or []:
            if s.get("name"):
                out.setdefault(norm(s["name"]), s["id"])
        if page >= data["totalPages"] or page >= 5:
            return out
        page += 1


def resolve(client, cfg, cache_path, now=time.time):
    corridor = cfg["corridor"]
    fp = _fingerprint(corridor)
    try:
        with open(cache_path) as f:
            cached = json.load(f)
        if cached.get("fingerprint") == fp and now() - cached.get("at", 0) < MAX_AGE_S:
            return cached
    except (OSError, ValueError):
        pass

    names_needed = any(isinstance(x, str) for p in corridor["pairs"] for x in p["from"] + p["to"])
    by_name = _all_stations(client) if names_needed else {}
    unresolved = []

    def ids(entries):
        out = []
        for e in entries:
            if isinstance(e, int):
                out.append(e)
            elif norm(e) in by_name:
                out.append(by_name[norm(e)])
            else:
                unresolved.append(e)
        return out

    pairs = [{"from": ids(p["from"]), "to": ids(p["to"])} for p in corridor["pairs"]]
    carriers = list(corridor["carrier_codes"])
    if corridor["carrier_names"]:
        data, _ = client.get("/api/v1/dictionaries/carriers", None, "CarriersResponse", prio="static")
        for c in data["carriers"] or []:
            if any(norm(n) in norm(c.get("name") or "") for n in corridor["carrier_names"]):
                carriers.append(c["code"])
    res = {"fingerprint": fp, "at": now(), "pairs": pairs, "carriers": sorted(set(carriers)),
           "unresolved": unresolved}
    if unresolved:
        log.warning("unresolved corridor stations: %s", unresolved)
    tmp = cache_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(res, f, ensure_ascii=False)
    os.replace(tmp, cache_path)
    return res
