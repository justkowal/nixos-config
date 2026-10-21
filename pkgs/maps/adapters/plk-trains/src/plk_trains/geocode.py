"""Stop coordinates. PLK publishes none, so positions come from the local Nominatim (OSM).

Every coordinate produced here is derived, not source data (flagged in stops.txt and attributions).
"""
import json
import logging
import os
import time
import urllib.parse
import urllib.request

log = logging.getLogger("plk.geocode")
RETRY_MISSING_S = 7 * 86400
STATION_TYPES = {"station", "halt", "stop", "tram_stop", "stop_position", "platform"}
STATION_CATEGORIES = {"railway", "public_transport"}


def pick(results):
    for r in results:
        if r.get("category") in STATION_CATEGORIES or r.get("type") in STATION_TYPES:
            return float(r["lat"]), float(r["lon"])
    return None


class Geocoder:
    def __init__(self, cfg, cache_path, overrides_path, fetch=None, clock=time.time, sleep=time.sleep):
        self.cfg = cfg["geocode"]
        self.cache_path, self.overrides_path = cache_path, overrides_path
        self.fetch = fetch or self._http
        self.clock, self.sleep = clock, sleep
        self.last = 0.0
        self.cache = {}
        try:
            with open(cache_path) as f:
                self.cache = json.load(f)
        except (OSError, ValueError):
            pass
        self.overrides = {}
        try:
            with open(overrides_path) as f:
                self.overrides = json.load(f)
        except (OSError, ValueError):
            pass

    def _http(self, name):
        q = urllib.parse.urlencode({"q": name, "format": "jsonv2", "limit": 5, "countrycodes": "pl"})
        req = urllib.request.Request(self.cfg["base_url"] + "/search?" + q,
                                     headers={"User-Agent": "kowal-lab-maps-adapter/0.1 (personal use)"})
        with urllib.request.urlopen(req, timeout=self.cfg["timeout_s"]) as r:
            return json.loads(r.read(1_000_000))

    def locate(self, station_id, name):
        """Returns (lat, lon, source) or None. source is 'override' or 'osm-nominatim'."""
        sid = str(station_id)
        if sid in self.overrides:
            lat, lon = self.overrides[sid]
            return lat, lon, "override"
        hit = self.cache.get(sid)
        if hit and hit.get("name") == name:
            if hit.get("lat") is not None:
                return hit["lat"], hit["lon"], "osm-nominatim"
            if self.clock() - hit["at"] < RETRY_MISSING_S:
                return None
        wait = self.last + self.cfg["min_spacing_s"] - self.clock()
        if wait > 0:
            self.sleep(wait)
        self.last = self.clock()
        try:
            found = pick(self.fetch(name))
        except (OSError, ValueError) as e:
            log.warning("geocode failed for %s: %s", sid, type(e).__name__)
            return None
        self.cache[sid] = {"name": name, "at": self.clock(),
                           "lat": found[0] if found else None, "lon": found[1] if found else None}
        self._save()
        return (found[0], found[1], "osm-nominatim") if found else None

    def _save(self):
        tmp = self.cache_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.cache, f, ensure_ascii=False)
        os.replace(tmp, self.cache_path)
