#!/usr/bin/env bash
# Builds the routing graph on the desktop and pushes it to the Pi. The desktop initiates every transfer.
#
#   MAPS_CONTACT=you@example.org ./build-graph.sh [--refresh-osm] [--no-push] [--allow-validator-errors]
#
# Needs nix and docker. The Pi never holds a credential for this machine.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${NIXOS_CONFIG_DIR:-$(cd "$HERE/../.." && pwd)}
W=${MAPS_BUILD_DIR:-$HOME/maps-build}
PI_HOST=${MAPS_PI_HOST:-nixos-rpi4.lab}
PUSH_KEY=${MAPS_PUSH_KEY:-$HOME/.ssh/maps_push_ed25519}   # the Pi lets it write into the upload directory and nothing else
PULL_KEY=${MAPS_PULL_KEY:-$HOME/.ssh/maps_pull_ed25519}   # the Pi lets it read the export folder and nothing else
CONTACT=${MAPS_CONTACT:?set MAPS_CONTACT to the address that goes into the download User-Agent}
UA="kowal-lab-maps/0.1 (personal use; contact $CONTACT)"
VALIDATOR_VERSION=8.0.1
VALIDATOR_SHA256=${VALIDATOR_SHA256:-19293ddd9b6f954f216d4f12054bd8a3232921751c4484339e339764a91000e2}   # v8.0.1 cli jar, checked on download
REFRESH=0 PUSH=1 ALLOW_ERR=0
for a in "$@"; do case $a in --refresh-osm) REFRESH=1 ;; --no-push) PUSH=0 ;; --allow-validator-errors) ALLOW_ERR=1 ;; *) echo "unknown flag $a" >&2; exit 2 ;; esac; done

# the graph file is tied to the OTP version, so the image must be the one the Pi runs
OTP_IMAGE=$(grep -o 'opentripplanner/opentripplanner@sha256:[0-9a-f]*' "$REPO/hosts/rpi4/maps.nix" | head -1)
[ -n "$OTP_IMAGE" ] || { echo "cannot read the OTP image pin from hosts/rpi4/maps.nix" >&2; exit 1; }

mkdir -p "$W/osm" "$W/feeds" "$W/graph" "$W/reports" "$W/tools"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
PY='(builtins.getFlake "nixpkgs").legacyPackages.x86_64-linux.python3.withPackages (p: [p.pyyaml p.shapely p.pyproj])'
py() { nix shell --impure --expr "$PY" -c python3 "$@"; }
rs() { if command -v rsync >/dev/null; then rsync "$@"; else nix shell nixpkgs#rsync -c rsync "$@"; fi; }
sshopt() { echo "ssh -F /dev/null -i $1 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"; }

# ---- 1. OSM: weekly, conditional, then cut by voivodeship boundary + 10 km and prune minor roads outside the cities
osm_stale() { [ ! -f "$W/osm/scope-pruned.osm.pbf" ] || [ -n "$(find "$W/osm/downloaded-at.txt" -mtime +7 2>/dev/null)" ]; }
if [ $REFRESH = 1 ] || osm_stale; then
  log "OSM: downloading extracts (conditional requests, 3 s apart)"
  cd "$W/osm"
  for r in poland/slaskie poland/malopolskie poland/opolskie poland/lodzkie poland/swietokrzyskie poland/podkarpackie czech-republic slovakia; do
    f=$(basename "$r")-latest.osm.pbf
    etag=(); [ -f "$f.etag" ] && etag=(--etag-compare "$f.etag")
    curl -sSL -A "$UA" --etag-save "$f.etag" "${etag[@]}" -z "$f" -o "$f" "https://download.geofabrik.de/europe/$r-latest.osm.pbf"
    sleep 3
  done
  date -u > downloaded-at.txt
  log "OSM: cutting and pruning"
  nix shell nixpkgs#osmium-tool -c bash -c '
    osmium tags-filter -O -o sl.pbf slaskie-latest.osm.pbf r/ISO3166-2=PL-24
    osmium tags-filter -O -o ma.pbf malopolskie-latest.osm.pbf r/ISO3166-2=PL-12
    osmium export -O -f geojson --geometry-types=polygon -o sl.geojson sl.pbf
    osmium export -O -f geojson --geometry-types=polygon -o ma.geojson ma.pbf'
  py - <<'PYEOF'
import json
from shapely.geometry import shape, mapping
from shapely.ops import unary_union, transform
from pyproj import Transformer
to_m = Transformer.from_crs(4326, 2180, always_xy=True).transform
to_ll = Transformer.from_crs(2180, 4326, always_xy=True).transform
g = [shape(f["geometry"]) for fn in ("sl.geojson", "ma.geojson") for f in json.load(open(fn))["features"] if shape(f["geometry"]).geom_type in ("Polygon", "MultiPolygon") and shape(f["geometry"]).area > 0.5]
b = transform(to_ll, transform(to_m, unary_union(g)).buffer(10000).simplify(200))
json.dump({"type": "FeatureCollection", "features": [{"type": "Feature", "properties": {}, "geometry": mapping(b)}]}, open("scope.geojson", "w"))
PYEOF
  nix shell nixpkgs#osmium-tool -c bash -c '
    osmium merge -O -o merged.osm.pbf *-latest.osm.pbf
    osmium extract -O -s smart -p scope.geojson -o scope.osm.pbf merged.osm.pbf
    for b in "19.70,49.95,20.25,50.15" "18.50,50.10,19.40,50.45" "18.95,50.70,19.30,50.90"; do osmium extract -O -b $b -s smart -o city-$(echo $b | tr -d ".,").osm.pbf scope.osm.pbf; done
    osmium tags-filter -O -o main.osm.pbf scope.osm.pbf w/highway=motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link,unclassified,residential,living_street w/railway=rail,station,halt,platform w/public_transport r/type=route r/public_transport n/railway=station,halt,tram_stop n/public_transport n/highway=bus_stop
    osmium merge -O -o pruned.osm.pbf city-*.osm.pbf main.osm.pbf
    osmium sort -O -o scope-pruned.osm.pbf pruned.osm.pbf
    rm -f merged.osm.pbf pruned.osm.pbf'
  cd - >/dev/null
else
  log "OSM: extract is younger than a week, reusing it (--refresh-osm forces a new download)"
fi
OSM_TS=$(nix shell nixpkgs#osmium-tool -c osmium fileinfo -e -g data.timestamp.last "$W/osm/scope-pruned.osm.pbf" 2>/dev/null || echo unknown)

# ---- 2. feeds: registry and local files come from the Pi, static downloads happen here
log "feeds: reading the registry from the Pi"
rm -rf "$W/feeds" && mkdir -p "$W/feeds/local"
mkdir -p "$W/feeds/src"
rs -a -e "$(sshopt "$PULL_KEY")" "maps-pull@$PI_HOST:." "$W/feeds/src/" || log "feeds: nothing exported yet, assuming an empty registry"
cp "$W/feeds/src/feeds.yaml" "$W/feeds/feeds.yaml" 2>/dev/null || echo "feeds: []" > "$W/feeds/feeds.yaml"
cp "$W/feeds/src/feeds-local"/* "$W/feeds/local/" 2>/dev/null || true
export FEED_CONTACT="$CONTACT"; py "$HERE/fetch_feeds.py" "$W/feeds" "$UA"

# ---- 2b. feeds without shapes get routes derived from OSM (ids start with derived-), originals are kept next to them
for z in "$W"/feeds/*-gtfs.zip; do
  [ -f "$z" ] || continue
  id=$(basename "$z" -gtfs.zip)
  rc=0; nix shell nixpkgs#osmium-tool nixpkgs#python3 -c python3 "$HERE/derive_shapes.py" "$z" "$z.shaped" "$W/osm/scope-pruned.osm.pbf" "$W/reports/shapes-$id.json" >/dev/null || rc=$?
  case $rc in
    0) mv "$z" "$W/feeds/$id-original.bak" && mv "$z.shaped" "$z"; log "shapes: $id derived $(jq -c '[.derived,.partial,.straight_segments]' "$W/reports/shapes-$id.json") (patterns, partial, straight segments)" ;;
    3) ;;
    *) rm -f "$z.shaped"; log "shapes: $id failed, using the feed as published" ;;
  esac
done

# ---- 3. validate every static feed with the MobilityData validator
FEEDS=$(jq -r '.[].id' "$W/feeds/feeds.json" 2>/dev/null || true)
if [ -n "$FEEDS" ]; then
  JAR="$W/tools/gtfs-validator-$VALIDATOR_VERSION-cli.jar"
  if [ ! -f "$JAR" ]; then
    log "validator: downloading $VALIDATOR_VERSION"
    curl -sSL -A "$UA" -o "$JAR" "https://github.com/MobilityData/gtfs-validator/releases/download/v$VALIDATOR_VERSION/gtfs-validator-$VALIDATOR_VERSION-cli.jar"
  fi
  [ -z "$VALIDATOR_SHA256" ] || echo "$VALIDATOR_SHA256  $JAR" | sha256sum -c - >/dev/null || { echo "validator checksum mismatch" >&2; exit 1; }
  for id in $FEEDS; do
    out="$W/reports/$STAMP/$id"; mkdir -p "$out"
    nix shell nixpkgs#openjdk17_headless -c java -jar "$JAR" -i "$W/feeds/$id-gtfs.zip" -o "$out" >/dev/null 2>&1 || true
    errs=$(jq '[.notices[]? | select(.severity=="ERROR") | .totalNotices] | add // 0' "$out/report.json" 2>/dev/null || echo "-1")
    warns=$(jq '[.notices[]? | select(.severity=="WARNING") | .totalNotices] | add // 0' "$out/report.json" 2>/dev/null || echo 0)
    log "validator: $id errors=$errs warnings=$warns (report in $out)"
    if [ "$errs" != 0 ] && [ $ALLOW_ERR = 0 ]; then echo "refusing to build: $id has validator errors" >&2; exit 1; fi
  done
fi

# ---- 4. build
G="$W/graph/$STAMP"; mkdir -p "$G"
cp "$W/osm/scope-pruned.osm.pbf" "$G/"
cp "$W/feeds"/*-gtfs.zip "$G/" 2>/dev/null || true
py "$HERE/otp_config.py" "$W/feeds/feeds.json" "$W/feeds/feeds.yaml" "$G"
# traffic signal nodes for the navigation app's vehicle animation, a few hundred kB
nix shell nixpkgs#osmium-tool nixpkgs#jq -c bash -c "osmium tags-filter -O -o '$G/sig.pbf' '$W/osm/scope-pruned.osm.pbf' n/highway=traffic_signals n/crossing=traffic_signals \
  && osmium export -O -f geojsonseq --geometry-types=point -o '$G/sig.geojsonseq' '$G/sig.pbf' \
  && tr -d '\\036' < '$G/sig.geojsonseq' | jq -sc '[.[]|[(.geometry.coordinates[0]*100000|round/100000),(.geometry.coordinates[1]*100000|round/100000)]]' > '$G/signals.json'" \
  && log "signals: $(jq length "$G/signals.json") nodes" || log "signals: extraction failed, the app animates without traffic lights"
rm -f "$G/sig.pbf" "$G/sig.geojsonseq"
log "build: OTP $OTP_IMAGE"
docker image inspect "$OTP_IMAGE" >/dev/null 2>&1 || docker pull -q "$OTP_IMAGE" >/dev/null
t0=$(date +%s)
docker run -d --name otp-build -e JAVA_OPTS="-Xmx12g" -v "$G:/var/opentripplanner" "$OTP_IMAGE" --build --save >/dev/null
peak=0
while [ "$(docker inspect -f '{{.State.Running}}' otp-build 2>/dev/null)" = true ]; do
  v=$(docker stats --no-stream --format '{{.MemUsage}}' otp-build 2>/dev/null | awk '{v=$1; if (v~/GiB/) {sub("GiB","",v); print int(v*1024)} else if (v~/MiB/) {sub("MiB","",v); print int(v)} else print 0}')
  [ "${v:-0}" -gt "$peak" ] && peak=$v; sleep 2
done
rc=$(docker inspect -f '{{.State.ExitCode}}' otp-build); docker logs otp-build > "$G/build.log" 2>&1; docker rm otp-build >/dev/null
[ "$rc" = 0 ] && [ -f "$G/graph.obj" ] || { echo "OTP build failed, see $G/build.log" >&2; exit 1; }
secs=$(( $(date +%s) - t0 ))
log "build: $secs s, peak $peak MiB, graph $(du -m "$G/graph.obj" | cut -f1) MB"

py - "$G" "$W/feeds/feeds.json" "$OTP_IMAGE" "$OSM_TS" "$secs" "$peak" <<'PYEOF'
import hashlib, json, sys, time
g, feeds, image, ts, secs, peak = sys.argv[1:]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
fl = json.load(open(feeds)) if feeds and __import__("os").path.exists(feeds) else []
m = {"otp_image": image, "otp_version": "2.10.0", "graph_sha256": sha(g + "/graph.obj"), "graph_bytes": __import__("os").path.getsize(g + "/graph.obj"),
     "build_config_sha256": sha(g + "/build-config.json"), "router_config_sha256": sha(g + "/router-config.json"),
     "osm_data_timestamp": ts, "osm_source": "download.geofabrik.de, pruned outside Krakow, Katowice conurbation and Czestochowa",
     "attribution": "© OpenStreetMap contributors (ODbL)", "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
     "build_seconds": int(secs), "build_peak_mib": int(peak),
     "feeds": [{"id": f["id"], "sha256": f["sha256"], "bytes": f["bytes"], "license": f.get("license"), "attribution": f.get("attribution")} for f in fl]}
json.dump(m, open(g + "/manifest.json", "w"), indent=1)
PYEOF

# ---- 5. push: upload directory only, the READY marker last so the Pi never sees a half-copied graph
if [ $PUSH = 1 ]; then
  log "push: maps-push@$PI_HOST:$STAMP"
  rs -a -e "$(sshopt "$PUSH_KEY")" "$G/graph.obj" "$G/build-config.json" "$G/router-config.json" "$G/manifest.json" $([ -f "$G/signals.json" ] && echo "$G/signals.json") "maps-push@$PI_HOST:./$STAMP/"
  : > "$G/READY"
  rs -a -e "$(sshopt "$PUSH_KEY")" "$G/READY" "maps-push@$PI_HOST:./$STAMP/READY"
  log "pushed; the Pi verifies, stage-tests and swaps it in on its own"
else
  log "built $G (not pushed)"
fi
