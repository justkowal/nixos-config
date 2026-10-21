# Picks up a graph pushed by the desktop: verify, stage-test, swap in, keep one previous. A graph that fails is quarantined, never loaded.
# env: DATA (maps directory), OTP_IMAGE, JAVA_OPTS, MIN_FREE_GB
G=$DATA/graph
UP=$G/upload CUR=$G/current PREV=$G/previous QUAR=$G/quarantine
MIN_FREE_GB=${MIN_FREE_GB:-6}
mkdir -p "$QUAR"
log() { echo "graph-watch: $*"; }

# the gateway reads the manifest from a stable folder, because it cannot follow the directory renames of a swap
if [ -f "$CUR/manifest.json" ] && ! cmp -s "$CUR/manifest.json" "$G/info/manifest.json" 2>/dev/null; then
  mkdir -p "$G/info"; cp "$CUR/manifest.json" "$G/info/manifest.json"
fi
if [ -f "$CUR/signals.json" ] && ! cmp -s "$CUR/signals.json" "$G/info/signals.json" 2>/dev/null; then cp "$CUR/signals.json" "$G/info/signals.json"; fi
dir=$(find "$UP" -mindepth 2 -maxdepth 2 -name READY -printf '%h\n' | sort | tail -1)
[ -n "$dir" ] || { log "nothing to do"; exit 0; }
name=$(basename "$dir")

reject() {
  log "REJECTED $name: $1"
  mv "$dir" "$QUAR/$name" 2>/dev/null || rm -rf "$dir"
  printf '{"rejected":"%s","reason":"%s","at":"%s"}\n' "$name" "$1" "$(date -u +%FT%TZ)" > "$G/last-rejection.json"
  systemctl start podman-mcp-otp 2>/dev/null || true
  exit 1
}

free_gb() { df -BG --output=avail /srv/data | tail -1 | tr -dc '0-9'; }
[ "$(free_gb)" -ge "$MIN_FREE_GB" ] || { log "less than ${MIN_FREE_GB} GB free, leaving $name in place"; exit 1; }

# ---- verify the manifest against the files and against what this Pi runs
M=$dir/manifest.json
[ -f "$M" ] && [ -f "$dir/graph.obj" ] || reject "manifest or graph missing"
[ "$(jq -r .otp_image "$M")" = "$OTP_IMAGE" ] || reject "OTP image in the manifest does not match the one this Pi runs"
[ "$(sha256sum "$dir/graph.obj" | cut -d' ' -f1)" = "$(jq -r .graph_sha256 "$M")" ] || reject "graph checksum mismatch"
for f in build-config router-config; do
  [ "$(sha256sum "$dir/$f.json" | cut -d' ' -f1)" = "$(jq -r ".${f//-/_}_sha256" "$M")" ] || reject "$f checksum mismatch"
done
size=$(stat -c %s "$dir/graph.obj")
[ "$size" = "$(jq -r .graph_bytes "$M")" ] || reject "graph size differs from the manifest"
[ "$size" -gt 20000000 ] && [ "$size" -lt 3000000000 ] || reject "graph size $size is not plausible"

# ---- stage test in a throwaway OTP; the production one is stopped meanwhile because the Pi cannot hold two
ip_of() { podman inspect -f '{{(index .NetworkSettings.Networks "mcp-internal").IPAddress}}' "$1"; }
ready() { for _ in $(seq 1 150); do [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://$1:8080/otp")" = 200 ] && return 0; sleep 2; done; return 1; }
gql() { curl -s -m 90 -X POST "http://$1:8080/otp/gtfs/v1" -H 'Content-Type: application/json' -d "$2"; }
dist() { gql "$1" "{\"query\":\"{ planConnection(origin:{location:{coordinate:{latitude:$2,longitude:$3}}} destination:{location:{coordinate:{latitude:$4,longitude:$5}}} modes:{direct:[$6]}) { edges { node { legs { distance } } } } }\"}" | jq '[.data.planConnection.edges[0].node.legs[].distance] | add // 0 | floor'; }
smoke() {
  local ip=$1 manifest=$2 w c id
  w=$(dist "$ip" 50.0645 19.9233 50.0615 19.9371 WALK)      # AGH to the Rynek, about 1.4 km on foot
  c=$(dist "$ip" 50.0615 19.9371 50.2661 19.0253 CAR)       # Krakow to Katowice, about 80 km by car
  log "smoke: walk ${w} m, car ${c} m"
  [ "${w:-0}" -ge 1000 ] && [ "${w:-0}" -le 2500 ] || return 1
  [ "${c:-0}" -ge 60000 ] && [ "${c:-0}" -le 110000 ] || return 1
  for id in $(jq -r '.feeds[].id' "$manifest"); do
    gql "$ip" '{"query":"{ feeds { feedId } }"}' | jq -e --arg id "$id" '[.data.feeds[].feedId] | index($id)' >/dev/null || { log "smoke: feed $id missing from the graph"; return 1; }
  done
}

systemctl stop podman-mcp-otp 2>/dev/null || true
podman rm -f otp-staging >/dev/null 2>&1 || true
# staging has no outbound network and an empty router config, so it never polls a realtime feed
echo '{}' > "$G/staging-router-config.json"
chmod 644 "$G/staging-router-config.json"
podman run -d --name otp-staging --network mcp-internal --user 65534:65534 --read-only --tmpfs /tmp:rw,size=64m,mode=1777 \
  --memory="${OTP_MEMORY:-1900m}" --cap-drop=ALL --security-opt=no-new-privileges -e "JAVA_OPTS=$JAVA_OPTS" \
  -v "$dir:/var/opentripplanner:ro" -v "$G/staging-router-config.json:/var/opentripplanner/router-config.json:ro" \
  "$OTP_IMAGE" --load --serve >/dev/null || reject "staging container did not start"
sip=$(ip_of otp-staging)
if ! ready "$sip" || ! smoke "$sip" "$M"; then
  podman logs --tail 5 otp-staging >&2 || true
  podman rm -f otp-staging >/dev/null 2>&1
  reject "staging load or smoke tests failed"
fi
podman rm -f otp-staging >/dev/null
log "staging passed for $name"

# ---- swap: current becomes previous (one only), the new graph becomes current, production restarts on it
rm -f "$dir/READY"
rm -rf "$PREV"
[ -d "$CUR" ] && mv "$CUR" "$PREV"
mv "$dir" "$CUR"
systemctl start podman-mcp-otp
pip=""
for _ in $(seq 1 30); do pip=$(ip_of mcp-otp 2>/dev/null || true); [ -n "$pip" ] && break; sleep 2; done
if [ -z "$pip" ] || ! ready "$pip" || ! smoke "$pip" "$CUR/manifest.json"; then
  log "production failed on $name, rolling back"
  systemctl stop podman-mcp-otp
  mv "$CUR" "$QUAR/$name"
  [ -d "$PREV" ] && mv "$PREV" "$CUR"
  systemctl start podman-mcp-otp
  printf '{"rejected":"%s","reason":"production smoke failed after swap","at":"%s"}\n' "$name" "$(date -u +%FT%TZ)" > "$G/last-rejection.json"
  exit 1
fi
publish_info() {
  mkdir -p "$G/info"; cp "$CUR/manifest.json" "$G/info/manifest.json.tmp" && mv "$G/info/manifest.json.tmp" "$G/info/manifest.json"
  # optional extra for the navigation app; a graph without it simply has no traffic light animation
  if [ -f "$CUR/signals.json" ] && jq -e 'type=="array" and length<60000' "$CUR/signals.json" >/dev/null 2>&1; then cp "$CUR/signals.json" "$G/info/signals.json.tmp" && mv "$G/info/signals.json.tmp" "$G/info/signals.json"; fi
}
publish_info
printf '{"swapped":"%s","at":"%s"}\n' "$name" "$(date -u +%FT%TZ)" > "$G/last-swap.json"
# anything older that was left in the upload directory is superseded
find "$UP" -mindepth 1 -maxdepth 1 -type d -name '2*' ! -name "$name" -exec rm -rf {} +
log "swapped in $name"
