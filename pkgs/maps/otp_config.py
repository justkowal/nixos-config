"""Write build-config.json and router-config.json for the feeds in feeds.json.

usage: otp_config.py <feeds.json> <feeds.yaml> <outdir>
"""
import json
import os
import sys

feeds = json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1]) else []
out = sys.argv[3]
build = {"osm": [{"source": "scope-pruned.osm.pbf", "osmTagMapping": "default", "timeZone": "Europe/Warsaw"}],
         "transitModelTimeZone": "Europe/Warsaw",
         "transitFeeds": [{"type": "gtfs", "feedId": f["id"], "source": f"file:/var/opentripplanner/{f['id']}-gtfs.zip"} for f in feeds]}
updaters = []
kinds = {"trip_updates": "stop-time-updater", "vehicle_positions": "vehicle-positions", "service_alerts": "real-time-alerts"}
for f in feeds:
    for key, typ in kinds.items():
        url = (f.get("realtime") or {}).get(key)
        if url:
            updaters.append({"type": typ, "feedId": f["id"], "url": url, "frequency": f"{max(int(f.get('poll_seconds', 30)), 30)}s"})
# the walk to and from stops is the expensive part of a search in a dense city on the Pi: cap it
router = {"updaters": updaters, "routingDefaults": {"accessEgress": {"maxDuration": "20m", "maxStopCount": 120}}}
json.dump(build, open(os.path.join(out, "build-config.json"), "w"), indent=1)
json.dump(router, open(os.path.join(out, "router-config.json"), "w"), indent=1)
print(f"build-config: {len(feeds)} feed(s); router-config: {len(updaters)} updater(s)")
