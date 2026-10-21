"""The endpoints the site's own single-page app calls, with shape checks.

The site is kiedyPrzyjedzie.pl (Vue front end). Paths come from its public JS bundle.
A payload with an unexpected shape raises SourceError and is never stored.
"""
import base64
import json
import re
import urllib.parse

from guard import SourceError, fetch


def _obj(body, *keys):
    try:
        d = json.loads(body)
    except ValueError as e:
        raise SourceError("payload is not JSON") from e
    if not isinstance(d, dict) or any(k not in d for k in keys):
        raise SourceError("unexpected payload shape, missing %s" % (keys,))
    return d


class Source:
    def __init__(self, guard, base_url, user_agent):
        self.g, self.base, self.ua = guard, base_url.rstrip("/"), user_agent

    def _get(self, lane, path, **kw):
        return fetch(self.g, lane, self.base + path, self.ua, **kw)[2]

    def stops_revision(self):
        body = self._get("static", "/", expect="html", must_contain=b'id="app"')
        m = re.search(rb'data-stops-revision="(\d+)"', body)
        if not m:
            raise SourceError("stops revision not found on the start page")
        return int(m.group(1))

    def stops(self, rev):
        d = _obj(self._get("static", f"/stops?rev={int(rev)}", max_bytes=3_000_000), "stops")
        out = {}
        for r in d["stops"]:
            if not (isinstance(r, list) and len(r) >= 7 and isinstance(r[0], str)):
                raise SourceError("unexpected stop row")
            out[r[0]] = {"designator": r[1], "name": r[2], "lon": r[3] / 1e6, "lat": r[4] / 1e6,
                         "station": bool(r[6])}
        if not out:
            raise SourceError("empty stop list")
        return out

    def timetable(self, place_id, date):
        q = urllib.parse.quote(place_id, safe=":")
        d = _obj(self._get("static", f"/api/timetables/{q}?date={date}"), "departures")
        for x in d["departures"]:
            if not all(k in x for k in ("trip_id", "index", "departure")):
                raise SourceError("unexpected timetable row")
        return d["departures"]

    def trip(self, trip_id, index):
        d = _obj(self._get("static", f"/api/trip/{int(trip_id)}/{int(index)}"), "times", "line", "direction")
        for x in d["times"]:
            if not all(k in x for k in ("place_id", "departure_time", "index")):
                raise SourceError("unexpected trip stop row")
        return d

    def departures(self, place_ids):
        q = ",".join(urllib.parse.quote(p, safe=":") for p in place_ids)
        d = _obj(self._get("rt", f"/api/departures?places={q}"), "departures")
        for blk in d["departures"]:
            if "designator" not in blk or "rows" not in blk:
                raise SourceError("unexpected departures block")
        return d

    def trip_execution(self, execution_id, index):
        eid = base64.b64encode(execution_id.encode()).decode()
        return _obj(self._get("rt", f"/api/trip_execution/{eid}/{int(index)}"), "trip", "vehicle_trip_index")
