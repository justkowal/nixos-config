# mpk-czestochowa adapter

Internal adapter for MPK Czestochowa (city buses). Personal, non-commercial use. The
converted feeds stay internal and must never be published or shared.

Rozkladzik.pl is not used: the operator publishes an official GTFS and runs its own live
service, so no scraping of third-party sites is needed.

## R1 findings

| Source | robots.txt | Terms |
| --- | --- | --- |
| mpk.czest.pl (public Nextcloud share with timetable data) | `User-agent: *` / `Disallow:` (allows all) | No licence or terms on the share or in the data. The city's notice 5/2026 says the data feeds Google Transit. mkuran.pl lists the share as a public source. Licence is therefore unstated. |
| live.mpk.czest.pl (liveMPK, the operator's own app) | 404 (none) | Only a cookie/privacy policy; nothing on automated access. API is undocumented: it is the one the site's own JavaScript calls. |
| www.rozkladzik.pl | 404 (none, after a 302 from the bare domain) | Not read further, source not used. |

Nothing forbids automated access, but nothing grants a licence either. Open question for
the owner: acceptable for personal internal use? If the operator objects, set the kill switch.

## Endpoints used

Static (guard `static`):
- `PROPFIND /public/cloud/public.php/webdav/Dane%20rozk%C5%82adowe/` (list dated folders)
- `PROPFIND .../<newest folder not in the future>/` (etag of `GTFS_<date>.zip`)
- `GET .../GTFS_<date>.zip` only if the etag changed

The share token is the public one from the published link, not a secret. Auth is HTTP basic with
the token as user and an empty password, as Nextcloud public shares expect.

Live (guard `live`):
- `GET https://live.mpk.czest.pl/api/vehicles` (vehicle list, once per 6 h and at start)
- socket.io (Engine.IO v3, websocket only) namespace `/vehicles_exec`: emit `vehicles` with a list of
  vehicle IDs, receive `vehiclesStatus` pushed about every 5 s. One handshake per connection,
  no polling.

No credentials anywhere. User-Agent on every request: `kowal-lab-maps-adapter/0.1 (personal use; contact hopkuba@gmail.com)`.

## Output (internal URLs, port 8080, no host ports)

- `/gtfs/mpk-czestochowa.zip`
- `/gtfs-rt/trip-updates.pb`, `/gtfs-rt/vehicle-positions.pb` (FULL_DATASET, header timestamp = receive time)
- `/health` (JSON; HTTP 503 only when no static feed exists)

No Alerts feed: the source only has free text messages with no machine readable route links.

## Static feed

The official GTFS is passed through. Changes made by `static.py`:
- `feed_info.txt`: added `feed_version` (folder date) and `feed_contact_url`
- `shapes.txt`: dropped `shape_dist_traveled` (publisher repeats values across different
  points, 601 validator errors). Shapes themselves are intact.
- added `attributions.txt` and `LICENSE.txt`; removed `[Content_Types].xml` and the header-only `transfers.txt`

IDs (`stop_id`, `route_id`, `trip_id`, `service_id`) are exactly the publisher's. Stability across
releases is the publisher's, not guaranteed here. The publisher releases a new folder every few
days to weeks, each valid about 2 weeks (current: 2026-10-19 to 2026-10-31). The adapter picks the
newest folder dated today or earlier, checked daily. The static zip therefore switches at the first
check on or after the new folder's date, so up to about a day of mismatch is possible at the changeover.
17 routes have `route_type` 0 (tram) in the source although the city has no trams; left as published.

## Realtime design

Run `foreignID` in liveMPK equals the static `trip_id` (verified live against the full official feed).
A run is accepted only if: the trip exists, its service is active on the run's local service date,
the stop count equals the static stop_times count, and at least 95% of scheduled times agree within 60 s.
Otherwise the vehicle is emitted in VehiclePositions without a trip descriptor and counted as unmatched in `/health`.

- VehiclePositions: position and timestamp from the source, vehicle id = fleet number (`taborNo`), label = side number,
  plate from `/api/vehicles` (published to riders). `current_stop_sequence`/`stop_id` = next stop with no recorded arrival.
  No speed or bearing (not provided).
- TripUpdates: only for trips with at least one recorded stop arrival. Stops with recorded times carry the observed delay
  (actual minus scheduled). Stops not recorded before the last recorded one are omitted. Stops after it carry the last
  observed delay (ESTIMATED: plain propagation, no prediction model). The source's own `delaySeconds` is not used
  because its sign convention is inverted and it disagrees with recorded times.
- The source exposes `driver` and `dutyID` in the run object. They are never read, stored or logged; fixtures have them removed.

Subscription strategy: connect, subscribe to all ~320 vehicles (about 1.5 MB per push), take the first push,
resubscribe only to vehicles with a position newer than 5 min (about 8 KB per vehicle per push), and repeat the
discovery every 5 min. Nothing is connected outside service: the static feed gives the running windows of yesterday's
and today's service dates plus 30 min margin. Outside them the adapter holds no connection and makes no request.
Freshness is the source's push rate (about 5 s position updates every 10 s) while in service. If no push arrives for 120 s the
feeds are served empty rather than stale.

## Rate limits and failure handling (`guard.py`, `config.toml`)

Every request, including each websocket handshake, goes through a per-source guard:
- minimum spacing 5 s plus 0-3 s random jitter
- hard budget 100 requests per rolling hour per source, persisted in `/data` so restarts cannot reset it
- exponential backoff on errors (10 s doubling to 15 min)
- circuit breaker for 6 h on HTTP 403 or 429, any 3xx (redirects are never followed), a block or bot challenge page
  (non-JSON body where JSON is expected, captcha or Cloudflare markers), or 5 consecutive errors; nothing retries through it
- kill switch: create `/data/KILL` or set `MPK_KILL=1`
- no proxies, no fingerprint spoofing, no extra accounts

Note: the websocket library hides the HTTP status of a failed handshake, so a ban there shows as repeated connect
errors (backoff, then breaker after 5). The next REST call (`/api/vehicles`) would show the real status.

Logs: method, URL without query, status, bytes, timing, breaker events. No bodies (the socket.io libraries log payloads at INFO and are capped at WARNING).

## Request budget

Steady state per day: static 3 requests (2 PROPFIND + 1 GET only when changed; 2 otherwise), live `/api/vehicles` about 4,
websocket handshakes about 1 plus reconnects. Normal day: under 15 requests per source against a 100/hour cap.
Used during development: mpk.czest.pl about 15 (robots, page, listings, GTFS, PDF, home page, 2 end-to-end runs);
live.mpk.czest.pl about 14 (robots, page, 2 JS bundles, 3 REST, 4 websocket sessions including 2 adapter runs);
rozkladzik.pl 2 (robots only). No ban, no 4xx other than the expected robots 404s, no quota event.

## Validation

- GTFS validator 8.0.1 on the patched zip: 0 errors. Reports in `reports/gtfs-validator-8.0.1-report.{json,html}`.
  Warnings, all publisher data and left as is:
  - `duplicate_route_name` (15): distinct route_ids with the same short and long name (line variants)
  - `mixed_case_recommended_field` (596): stop names are all upper case
  - `feed_expiration_date30_days` (1): the feed ends 2026-10-31, refreshed automatically
  - INFO `unknown_file`: our `LICENSE.txt`
- GTFS-RT: the MobilityData realtime validator has no release artifact (Maven build of a web app, needs network), so it was not
  run. `tests/validate_rt.py` parses the feeds with gtfs-realtime-bindings and checks header fields, unique entity ids, and that
  every trip_id, route_id, start_date service, stop_sequence/stop_id pair exists in the full official static feed.
  Result in `reports/gtfs-rt-structural-check.txt`: 32 of 32 checks pass, 3 of 3 live night vehicles matched.
- Tests: `python -m unittest discover -s tests` (16 tests, recorded fixtures only, no network).

## Limits and gaps

- Fixtures were recorded at night (3 active vehicles, line 80). A daytime load profile (about 60 vehicles, 0.5-1 MB per push) is not yet measured.
- In a live run 1 of 8 vehicles had a trip missing from the static feed (counted as `unknown trip`); cause unknown, possibly a
  newer timetable than the published folder.
- The aarch64 image was not built here (amd64 only); the lock file carries hashes for aarch64 wheels.
- Cancellations, skipped stops and alerts are not supported.
