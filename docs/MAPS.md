# Maps and transit (rpi4)

Local OpenStreetMap queries (`osm` MCP server) and street plus transit routing (`routing` MCP server) for Silesia and Lesser Poland. Nothing here calls a public OSM service. They are two more children of the gateway described in `MCP_GATEWAY.md`, behind the same bearer token, allowlist and audit log.

## Architecture

| Piece | Where | Notes |
| --- | --- | --- |
| Nominatim 5.3.2 (frozen database, 3.8 GB) | `mcp-nominatim` on the Pi, data on the HDD at `/srv/data/kowal-lab-maps/nominatim` | internal network only, about 550 MiB peak |
| OpenTripPlanner 2.10.0, pruned graph | `mcp-otp` on the Pi, graph in `graph/current` | `-Xmx800m`, serial GC, about 930 MiB peak |
| `osm` and `routing` servers | stdio children of `mcp-gateway` | `pkgs/mcp-gateway/osm_mcp.py`, `routing_mcp.py` |
| Graph build | the desktop, `pkgs/maps/build-graph.sh` | the desktop initiates every transfer |
| Graph swap | the Pi, `graph-watch` (timer every 2 minutes) | verify, stage-test, swap, one previous kept, failures quarantined |

Images are pinned by digest in `hosts/rpi4/maps.nix`. The desktop script reads the OTP pin from that file and refuses to build with any other image, because a graph file only loads in the OTP version that wrote it.

Both map containers sit on `mcp-internal`, which has no route out. The gateway reaches them there. A 4 GB swap file on the HDD sits behind zram as a safety net (unused so far).

## Data

- Extract: Geofabrik `slaskie`, `malopolskie`, `opolskie`, `lodzkie`, `swietokrzyskie`, `podkarpackie`, `czech-republic`, `slovakia`, cut along the two voivodeship boundaries plus 10 km.
- Pruned for the graph: full detail inside Krakow, the Katowice conurbation and Czestochowa; main roads, rail and stops elsewhere. 167 MB, 1.22 M street vertices (full: 449 MB, 2.33 M).
- Licence: ODbL. Attribution "© OpenStreetMap contributors" is in `osm_data_info` and in every tool output.
- Versions: `osm_data_info` (Nominatim and extract dates), `routing_data_info` (graph build time, OTP version, loaded feeds, rebuild pending).

## Measured (2026-10-21)

| | Desktop (16 cores) | Pi 4 |
| --- | --- | --- |
| Nominatim import | 18 min, 3.8 GB | serves from the HDD, 0.5 s per geocode, 548 MiB peak |
| OTP graph build (pruned, street only) | 57 s, 5.7 GiB peak at a 12 GB heap | not built on the Pi |
| OTP serving | 0.95 GiB at 800 MB heap | 929 MiB peak after a swap |

Full both-voivodeship graph: 1.35 GiB at a 1.5 GB heap, which does not fit next to Nominatim. The pruned graph does. A corridor-only graph saved little (0.97 GiB), so pruning the street network was the useful lever.

## Tools

osm (read): `osm_geocode`, `osm_reverse_geocode`, `osm_nearby`, `osm_query`, `osm_get_element`, `osm_data_info`.
routing (read): `route`, `transit_plan`, `stops_nearby`, `stop_departures`, `vehicle_positions`, `service_alerts`, `trip_detail`, `routing_data_info`, `feed_list`, `feed_validate`.
routing (write, hidden until enabled by name): `feed_add`, `feed_remove`, `feed_set_enabled`, `graph_rebuild_request`.

Limits: 60 osm calls and 30 routing calls per minute, 50 results, 30 000 characters of output, 5 km radius (1.5 km without a tag value), 0.25 degree bbox (0.06 without a value), 8 s database statement timeout. Audit lines carry only tool, class and status, never an argument.

`osm_nearby` and `osm_query` read the Nominatim database as the read-only role `osmro` over the internal network (`pg_hba.conf` is mounted from Nix). They cover the primary OSM tag of named objects only (amenity, shop, tourism and so on), not arbitrary tag combinations.

## Keys and channels

- Push: `~/.ssh/maps_push_ed25519` on the desktop. On the Pi it is the user `maps-push`, forced command `rrsync -wo graph/upload`, `restrict`, source limited to the desktop. It can write there and nothing else.
- Pull: `~/.ssh/maps_pull_ed25519`. User `maps-pull`, forced command `rrsync -ro export`. `maps-export-sync` copies `feeds.yaml` and `feeds-local/` into the export folder every minute, so the key never touches the gateway state.
- The Pi holds no credential for the desktop.

## Runbook

**Build and publish a graph now.** On the desktop: `MAPS_CONTACT=<address> pkgs/maps/build-graph.sh` (copy `pkgs/maps` and `pkgs/mcp-gateway/{stdio_mcp,routing_mcp}.py` and `hosts/rpi4/maps.nix` to `~/maps-build/repo` if there is no checkout). It downloads OSM weekly at most, pulls the registry, validates every feed with the MobilityData validator (v8.0.1, checksum pinned), builds, records time and peak RAM, and pushes. The Pi swaps it in within a few minutes. Flags: `--refresh-osm`, `--no-push`, `--allow-validator-errors`.

**Roll back to the previous graph.** On the Pi, as root: `systemctl stop podman-mcp-otp; mv graph/current graph/rejected; mv graph/previous graph/current; cp graph/current/manifest.json graph/info/; systemctl start podman-mcp-otp` (paths under `/srv/data/kowal-lab-maps`).

**A graph was quarantined.** Look at `graph/last-rejection.json` and `journalctl -u graph-watch`. Quarantined graphs are in `graph/quarantine/` and are never loaded. Delete them once understood. Common causes: checksum mismatch (copy interrupted), OTP image mismatch (the pin in `maps.nix` changed), failed stage test (bad feed).

**Add a feed.** Through the gateway: enable `feed_add` by name in `policy/tools.json`, call `feed_validate`, then `feed_add` (first call shows the findings, second call with `confirmed=true` adds it), then run the desktop build. Or edit `state/feeds.yaml` by hand (the file documents every field). Remove the feed tools from `enable` afterwards. Feeds with realtime URLs need `mcp-otp` to reach the internet: attach it to the `mcp` network in `maps.nix`.

**Remove a feed.** `feed_remove` with `confirmed=true` (or edit `feeds.yaml`), then rebuild. `routing_data_info` shows "rebuild pending" until a newer graph is live.

**Widen or shrink the scope.** Edit the polygon and city boxes in `build-graph.sh`, run with `--refresh-osm`. A bigger graph needs a bigger `-Xmx` in `maps.nix` (measure first). Nominatim must be re-imported for a different area.

**Rotate the desktop keys.** Generate new ones, put the public halves in `maps.nix` (`pushKey`, `pullKey`), deploy, delete the old files on the desktop.

**Free disk space.** `graph/previous`, `graph/quarantine`, old `podman images`. The watcher refuses to run with less than 6 GB free on `/srv/data`.

**Nominatim database.** It is a copy of the desktop import (frozen, no updates). To refresh: re-import on the desktop (`mediagis/nominatim`, `FREEZE=true`, `IMPORT_STYLE=full`), create the `osmro` role (see git history of this file's session notes: `CREATE ROLE osmro LOGIN; GRANT SELECT ON placex, country_name TO osmro;` plus read-only, `statement_timeout`, `jit=off`), stop `mcp-nominatim`, copy the data directory with `tar --numeric-owner` straight from the desktop (never through another machine), start it.

**The throwaway test feed** used during verification is gone: the registry is empty and the graph has no feeds.

## Known limits

- "Czestochowa Jasna Gora" resolves to a place 30 km away; "Jasna Gora Czestochowa" is right. No Wikipedia importance data was imported.
- `feed_validate` does basic checks on the Pi. The full MobilityData validator runs on the desktop during the build.
- Realtime feeds are not yet loaded: `stop_departures`, `vehicle_positions` and `service_alerts` return data only when a loaded feed has them.
- Komunikacja Jurajska is blocked: its host's `robots.txt` forbids automated access.

## KMK (Phase 2, 2026-10-21)

Source: ZTP Krakow, `https://gtfs.ztp.krakow.pl/`. The index lists three groups with these real file names:

| Feed id | Static | Realtime | Notes |
| --- | --- | --- | --- |
| `kmk-bus` | `GTFS_KRK_A.zip` (MPK buses, 19.6 MB, 65 791 trips, 2 992 stops) | `TripUpdates_A.pb`, `VehiclePositions_A.pb`, `ServiceAlerts_A.pb` | service to 2027-01-31 |
| `kmk-mobilis` | `GTFS_KRK_M.zip` (Mobilis buses, 2.7 MB, 20 118 trips) | `*_M.pb` | service to 2027-01-31 |
| `kmk-tram` | `GTFS_KRK_T.zip` (trams, 4.1 MB, 11 571 trips) | none shipped | see below |

- Licence: **unclear**. No licence text or terms page was found; `gtfs.ztp.krakow.pl/robots.txt` is a 404. The feeds are published openly by ZTP. `feeds.yaml` says "unclear" and credits "ZTP Krakow, MPK Krakow" / "Mobilis".
- Polling: the registry floors `poll_seconds` at 30, six realtime updaters in total (trip updates, vehicle positions, alerts for bus and Mobilis).
- Trip id matching, decoded with `gtfs-realtime-bindings`: bus TripUpdates 37 of 37 and VehiclePositions 16 of 16 match the static `trip_id`s; Mobilis 1 of 1 each. Headers are FULL_DATASET and 22 to 55 s old at sampling time.
- **Tram realtime is not shipped.** The tram TripUpdate id (`block_45_trip_1_service_1`) is not in the static tram file (0 of 1), its `route_id` is empty, tram VehiclePositions are empty, and the ZTP index page itself says there is no GTFS-RT for the tram group. The tram feed is loaded static only.
- The bus feed is empty around 04:00 to 04:30 local time (0 entities, no header timestamp): that is a service gap, not an outage.
- Validator (MobilityData 8.0.1): 0 errors on all three. Warnings are cosmetic: route long names containing the short name, stops far from their shape, services defined only through exception dates, unused shapes, the tram extended route type 900, one expired calendar entry.
- Hand check: line 192 and 125 departures at Dworzec Glowny Wschod from OTP (04:31, 04:36, 04:57, 05:00, 05:06) equal the static schedule for 2026-10-21.

Sizing: with the KMK feeds the graph is 242 MB (was 188 MB). Stripping shapes and limiting the service window did not shrink it. On the Pi the heap needs 1300 MB: 1000 MB loaded in 250 s and timed out the stage test, 1300 MB loads in about 107 s, uses 1.45 GB, and a cold 80 km car query takes 14 s (3 s warm). About 930 MB of the Pi's RAM stays free. OTP now also sits on the `mcp` network so the realtime updaters can reach ZTP; it publishes no port. The stage-test container has no outbound network and an empty router config.

Build: 76 s on the desktop, 6.4 GiB peak at a 12 GB heap.

## Adapters (Phase 3, built, not enabled)

All three live in `pkgs/maps/adapters/` and are not integrated: the feeds registry has no entry for them and nothing runs them.

- `mpk-czestochowa`: official static GTFS from the operator's public share (new folder every few days, about two weeks of validity), plus realtime from the operator's own live service (websocket, no polling). Runs are matched to trips and checked before use. Delays after the last observed stop are estimated by plain propagation. 16 tests pass, GTFS validator 0 errors, the official GTFS-RT validator has no offline release so a structural check was used instead. Licence of the feed is unstated. Request volume stays under about 15 per day per source.
- `plk-trains`: the official PLK open data API. Built and tested on fixtures derived from the OpenAPI spec only, because it needs the API key (never read). 32 tests pass, 0 validator errors. Stop coordinates come from the local Nominatim and are flagged. Budgets: Basic tier gives about 2-minute freshness at 64% of the daily limit, Standard allows 30 s polling. Open items are in its README (key file readability, station names, the carrier code of the Lesser Poland operator, first live run checks).
- `komunikacja-jurajska`: **not built**. `komunikacjajurajska.kiedyprzyjedzie.pl/robots.txt` says `Disallow: /` for everyone and the operator publishes no GTFS. Options: ask the operator or the vendor for permission or a feed, file a public information request, or drop it.

### Enabling an adapter (after you approve it)

Each adapter is off by default. In `hosts/rpi4/configuration.nix` (or any host module) set `lab.maps.adapters.mpk-czestochowa.enable = true;` or `lab.maps.adapters.plk-trains.enable = true;`, then deploy. The Pi builds the image from the adapter's Dockerfile, starts it on `mcp-internal` and `mcp` (outbound for its source, no port published), and copies its static zip into the export folder every minute.

Then register it by hand in `state/feeds.yaml` (the tools can never set `internal_adapter`):

```yaml
- id: mpk-czestochowa
  name: MPK Czestochowa
  static: adapter:mpk-czestochowa
  realtime:
    trip_updates: http://mcp-adapter-mpk-czestochowa:8080/gtfs-rt/trip-updates.pb
    vehicle_positions: http://mcp-adapter-mpk-czestochowa:8080/gtfs-rt/vehicle-positions.pb
  poll_seconds: 30
  license: "unstated by the operator"
  attribution: "MPK Czestochowa"
  enabled: true
  internal_adapter: true
```

For `plk-trains` use `static: adapter:plk-trains` and the URLs `.../gtfs-rt/trip-updates.pb` and `.../gtfs-rt/alerts.pb`. It needs the API key: `ssh nixos-rpi4.lab 'sudo sh -c "umask 077; cat > /var/lib/mcp-gateway/secrets/plk_api_key"' < /path/to/keyfile`; the module sets the file to `root:10001` mode 0640 so the container user can read it, and the container only starts once the file exists. Check `/health` of the adapter for `unresolved` station names and `match_ratio` at the first live run (see its README). Both adapters have a kill switch (`/data/KILL`).
