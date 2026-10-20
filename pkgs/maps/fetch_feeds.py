"""Collect the static GTFS feeds of the registry into one folder, with the same download rules as the routing server.

usage: fetch_feeds.py <dir> <user-agent>   (dir holds feeds.yaml and local/; writes <id>-gtfs.zip and feeds.json)
"""
import hashlib
import json
import os
import shutil
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, "..", "mcp-gateway"))
os.environ.setdefault("FEED_CONTACT", os.environ.get("MAPS_CONTACT", "unset"))
import yaml  # noqa: E402

from routing_mcp import read_zip, safe_open  # noqa: E402

d = sys.argv[1]
feeds = (yaml.safe_load(open(os.path.join(d, "feeds.yaml"))) or {}).get("feeds") or []
out = []
for f in feeds:
    if not f.get("enabled", True):
        continue
    fid, ref = f["id"], f["static"]
    dest = os.path.join(d, f"{fid}-gtfs.zip")
    if ref.startswith("file:"):
        shutil.copy(os.path.join(d, "local", ref[5:]), dest)
    elif f.get("internal_adapter"):
        sys.exit(f"{fid}: adapter feeds are collected by the adapter step, not here")
    else:
        open(dest, "wb").write(safe_open(ref, extra_ports=tuple(f.get("allow_ports") or [])))
    data = open(dest, "rb").read()
    read_zip(data)  # size, ratio and path checks before anything else touches it
    out.append({"id": fid, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "license": f.get("license"),
                "attribution": f.get("attribution"), "realtime": f.get("realtime"), "poll_seconds": f.get("poll_seconds", 30)})
    print(f"feed {fid}: {len(data)} bytes")
json.dump(out, open(os.path.join(d, "feeds.json"), "w"), indent=1)
print(f"{len(out)} feed(s)")
