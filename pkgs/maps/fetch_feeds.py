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
from trim_gtfs import trim  # noqa: E402



def resolve_ckan(ref):
    """ckan:<base>#<dataset>: the portal rotates the file name every few hours, so take the newest zip resource of the dataset."""
    base, dataset = ref[5:].split("#", 1)
    meta = json.loads(safe_open(f"{base}/api/3/action/package_show?id={dataset}", max_bytes=5_000_000))
    zips = [r for r in meta["result"]["resources"] if (r.get("format") or "").upper() == "ZIP" and r["url"].startswith(base + "/")]
    if not zips:
        sys.exit(f"{ref}: no zip resource on the portal")
    return max(zips, key=lambda r: r.get("last_modified") or "")["url"]


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
    elif f.get("internal_adapter") and ref.startswith("adapter:"):
        # the Pi copies each adapter's zip into its export folder; the pull key reads it from there
        shutil.copy(os.path.join(d, "src", "adapters", ref[8:] + ".zip"), dest)
    elif f.get("internal_adapter"):
        sys.exit(f"{fid}: an internal adapter feed needs static: adapter:<name>")
    else:
        if ref.startswith("ckan:"):
            ref = resolve_ckan(ref)
            print(f"feed {fid}: newest resource {ref.rsplit('/', 1)[-1]}")
        open(dest, "wb").write(safe_open(ref, extra_ports=tuple(f.get("allow_ports") or [])))
    if f.get("trim_days"):
        # whole-metropolis feeds expand every service day; the Pi cannot hold a month of them
        read_zip(open(dest, "rb").read())
        print(f"feed {fid}: trimmed to {f['trim_days']} days:", trim(dest, dest + ".trim", int(f["trim_days"])))
        os.replace(dest + ".trim", dest)
    data = open(dest, "rb").read()
    read_zip(data)  # size, ratio and path checks before anything else touches it
    out.append({"id": fid, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "license": f.get("license"),
                "attribution": f.get("attribution"), "realtime": f.get("realtime"), "poll_seconds": f.get("poll_seconds", 30)})
    print(f"feed {fid}: {len(data)} bytes")
json.dump(out, open(os.path.join(d, "feeds.json"), "w"), indent=1)
print(f"{len(out)} feed(s)")
