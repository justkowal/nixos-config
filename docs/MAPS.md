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
