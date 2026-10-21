# plk-trains adapter

Translates the official PKP PLK "Otwarte Dane Kolejowe" API into a static GTFS zip and GTFS-Realtime
(TripUpdates, Alerts) for trains between Kraków and Częstochowa. Internal Docker network only, for
OpenTripPlanner. Personal, non-commercial use. The converted feeds are never published or shared.

API version: `v1`, header `X-Api-Version: 1.0`, OpenAPI spec 1.1.4 (portal changelog up to 1.1.1 plus
unreleased items, read 2026-10-21). The schemas the adapter depends on are vendored in
`spec/openapi-subset.json` and every response is validated against them.

## Status

Built and tested on synthetic-from-spec fixtures only. No key-protected endpoint was ever called, so
the following are unverified until the first live run: the corridor station names, the dictionary
shapes, whether `plannedSequenceNumber` lines up with `orderNumber` (not relied on), the meaning of
`arrivalDay` for trimmed routes, and the `trainOrderId` convention. See "Open points".

## What the terms say (R1)

Read from `GET /api/v1/terms` v1.0 (effective 2025-12-31) and `/api/v1/privacy` on pdp-api.plk-sa.pl.

- `robots.txt` returns 404, so there is no crawler policy. This is an official keyed API anyway.
- Use is free within the limits. Permitted purposes (3.2) include passenger information apps, journey
  planning tools and analysis. A personal journey planner for the owner fits.
- Obligations (3.3): respect rate limits, do not share the key, use data for the stated purposes, do
  not overload the infrastructure, name the source (PKP Polskie Linie Kolejowe S.A.) when publishing.
- Forbidden (3.4): commercial resale of raw data, unlawful use, circumventing protections or limits,
  misleading about the source, harming the good name of PLK or carriers.
- No clause on caching or redistribution beyond that. Nothing here is published, but the source is
  still named in `attributions.txt` and `license.txt` inside the zip.
- Data is informational only and gives no basis for claims against carriers or PLK (5.5). The
  SLA target is 98 percent. Planned maintenance: first Tuesday of each month, 20:00 to 24:00 Warsaw
  time. The adapter does not call the API in that window (plus 15 minutes margin).
- Access can be blocked for breaking the terms, including attempts to bypass limits. Hence no second
  key and no workaround for quota, ever.
- Privacy policy: cookies and key-holder personal data only. The adapter never reads or logs the
  key-management endpoints.
- Breaking changes: new major version in the URL with at least 90 days of parallel running, email
  notice at least 30 days ahead to the address registered for the key. Watch
  https://pdp-api.plk-sa.pl/changelog.md. Contact: pdp-api@plk-sa.pl.

Requests made while researching (all without a key, spaced at least 3 s, honest User-Agent):
robots.txt, /api-documentation, /changelog.md, /api/v1/terms, /api/v1/privacy, swagger.json, one
404 guess for the spec path, and two `/api/v1/fields/*/csv`. The docs say the fields endpoints need
no key. In practice they answer 401 `MissingKey`, so the adapter does not use them.

## Endpoints used

All `GET`, JSON, base `https://pdp-api.plk-sa.pl`.

| Endpoint | Why | When |
|---|---|---|
| `/api/v1/dictionaries/stations` | resolve configured station names to IDs, one call with `pageSize=5000` | once, cached 90 days, or when the corridor config changes |
| `/api/v1/dictionaries/carriers` | only if `carrier_names` is configured | same |
| `/api/v1/data-version` | `schedulesVersion` GUID, skip re-pulling unchanged timetables | every 6 h |
| `/api/v1/schedules` | `fromStations`, `toStations`, `dateFrom`, `dateTo` (31 days), `dictionaries=true`, `fullRoute=false` | twice per refresh (one per direction), only when the version changed or fewer than 7 days remain |
| `/api/v1/operations` | `stations`, `withPlanned=true`, `fullRoutes=false`, `pageSize=2000` | adaptive, see below |
| `/api/v1/disruptions` | alerts, `dictionaries=true` | every 30 min |

Not used: `/apikey/*` (the tier is learned from the `X-RateLimit-*-Limit` response headers, which
saves a call and avoids personal data), `/shortened` variants (long names validate better), the
per-train route endpoints (one call per train would be far too expensive).

Pair filter: `fromStations`/`toStations` returns only trains running from one group to the other,
trimmed to that section. That is one cheap query instead of every train through Kraków Główny. The
cost is coverage: only through trains between the groups are in the feed, not local trains that run
only between two intermediate stops. Add more `[[corridor.pairs]]` in `config.toml` if needed.

## Auth and the secret

Key goes in the `X-API-Key` header only, read from `/run/secrets/plk_api_key` on every request
(never cached in a variable that outlives it, never logged, never in a URL). Docker secret name:
`plk_api_key`. Destination file on the Pi: `/var/lib/mcp-gateway/secrets/plk_api_key`, owner root,
mode 600. One line to run on the desktop (needs passwordless sudo on the Pi):

```
ssh PI_HOST 'sudo sh -c "umask 077; cat > /var/lib/mcp-gateway/secrets/plk_api_key"' < PATH_TO_KEY_FILE
```

Compose wiring (not included, the gateway is out of scope here):

```
secrets: { plk_api_key: { file: /var/lib/mcp-gateway/secrets/plk_api_key } }
services.plk-trains: image, secrets: [plk_api_key], volumes: [plk-trains-data:/data], no ports
```

Catch: a file secret keeps the host owner and mode, and the image runs as uid 10001, so root:root 600
is unreadable inside the container. Either run the service with `user: "0:0"`, `cap_drop: [ALL]`,
`read_only: true`, or make the file `root:10001` mode 640. Without a readable key the adapter makes
no requests and `/health` says `api key file missing or empty`.

## Quota and budget math

Fractions in `config.toml`: 60 percent of the hourly and 70 percent of the daily limit. The tier is
read from the headers of the first response (`Basic` is assumed until then). The API's own
`X-RateLimit-*-Remaining` counters are honoured too: realtime stops when remaining falls below the
reserve (40 percent hourly, 30 percent daily), which also protects the owner's interactive queries.
Static refreshes may use the reserve down to 10 percent left.

Whether `data-version` counts against the quota is not stated in the docs (it only needs a valid
key). It is counted as a request here. The key-info calls are not made.

Realtime pacing: `interval = active seconds left today / (daily allowance left * 0.9 - expected
alert polls)`, clamped to 30 s .. 900 s, divided by pages per poll. The interval therefore stretches
as the budget is spent. Quiet hours 00:30 to 04:00 Warsaw time: no operations polling (night trains
get no live delays then). Active time is about 20.5 h a day.

| | Basic 100/h, 1000/d | Standard 500/h, 5000/d | Premium 2000/h, 20000/d |
|---|---|---|---|
| Adapter caps (hour / day) | 60 / 700 | 300 / 3500 | 1200 / 14000 |
| Operations interval | about 120 s | 30 s (floor) | 30 s (floor) |
| Operations calls per day | about 590 | about 2460 | about 2460 |
| Alerts calls per day (30 min) | about 41 | about 41 | about 41 |
| Static per day, typical / worst | 4 / 12 | 4 / 12 | 4 / 12 |
| Total per day | about 640 (64%) | about 2510 (50%) | about 2510 (13%) |
| Peak per hour | about 32 | 122 | 122 |
| Left for owner and reserve | about 360 per day | about 2490 per day | about 17500 per day |

Static math: 4 `data-version` checks, plus 2 schedule calls per refresh. A refresh happens when the
version changes (worst case at every check, 8 calls a day) or about every 24 days for the window. The
stations dictionary is 1 call per 90 days.

Verdict: Basic works with roughly 2 minute freshness for delays. 30 s polling needs Standard. The
owner can ask for a higher tier at https://pdp-api.plk-sa.pl/limit-request. This adapter never files
that request. A second key or account to dodge limits is out of the question.
If `/operations` for the corridor needs more than one page, each page costs a request and the
interval stretches to compensate; check `realtime.pages` in `/health` after the first live run.

## Failure behaviour (R3)

- 429: quota signal, not a ban. Pause until the next hour boundary (or until `Retry-After`). If the
  daily counter is 0, or a second 429 follows within 15 minutes of resuming, pause until after
  Warsaw midnight. Shown in `/health` as `quota.quota_pause`.
- 403, any redirect, a non-JSON 200 (block page or challenge), or 5 consecutive errors: circuit
  breaker for 6 hours, persisted in `/data/limiter.json` so a restart does not reset it.
- 401: pause for 1 hour (bad or missing key).
- Other errors and timeouts: exponential backoff 30 s, 60 s, 120 s, up to 30 min.
- Schema mismatch: the response is rejected, the feed file is not replaced, `/health` shows
  `api schema changed`. It is not treated as a ban.
- Stale snapshot (older than 30 min by `X-Snapshot-Timestamp`): not published.
- Kill switch: create `/data/KILL` or set `PLK_KILL=1`.
- Spacing: at least 3 s plus jitter between any two requests, enforced in `limiter.py`.

## Output

- `GET /gtfs.zip` (ETag), `GET /gtfs-rt/trip-updates.pb`, `GET /gtfs-rt/alerts.pb`, `GET /health`.
  Rebuilt from the cached timetable at the first cycle after midnight, so the calendar window rolls
  without extra requests.
- Static: `agency`, `stops`, `routes`, `trips`, `stop_times`, `calendar_dates` (no `calendar.txt`),
  `feed_info`, `attributions`, `license.txt`. Timezone Europe/Warsaw.
- IDs: `trip_id = <scheduleId>-<orderId>[-<trainOrderId>]` (last part only if different from
  `orderId`), `service_id = svc-<trip_id>`, `stop_id = PLK station ID`, `route_id =
  <carrier>_<category>[_<train name>]`. Stable across regenerations.
- TripUpdates: `FULL_DATASET`, header timestamp = API snapshot time. Delay in seconds from the API's
  `arrivalDelayMinutes` and `departureDelayMinutes`. A cancelled train becomes a `CANCELED` trip, a
  cancelled stop becomes `SKIPPED`. Matching is by `trip_id` plus `start_date` (the operating date)
  and every stop must exist on that static trip; anything else is counted as unmatched and dropped.
  `/health` shows `match_ratio`. Updates are keyed on `stop_id` only, never on a guessed
  `stop_sequence`; a stop that appears twice on one trip gets no update.
- Alerts: disruptions that name a trip in the static feed, text in Polish. No VehiclePositions: the
  API has no positions.

## What is missing or estimated (R7)

- No stop coordinates in the API. Positions come from the local Nominatim (`mcp-nominatim:8080`,
  first result that is a railway or public transport object). They are flagged in `stops.txt`
  (`stop_desc`), `attributions.txt` and `license.txt`. Wrong ones can be fixed in
  `/data/stop_overrides.json` as `{"<stationId>": [lat, lon]}`. A stop without any position is dropped
  from its trips; a trip left with fewer than 2 stops is dropped. Both are counted in `/health`.
- No shapes. None invented.
- Arrival or departure missing at a stop: the other time is used for both (first and last stop).
  Stops with neither time are skipped. Stops whose type name contains "bez zatrzym" are skipped as
  pass-through; more can be listed by ID in `pass_through_stop_type_ids` once the stop-type
  dictionary has been looked at.
- `agency_url` is required by GTFS, the API gives none, so it is the API portal URL for all agencies.
- No `direction_id`, no platforms in GTFS. Headsign is the last stop of the trimmed section.
- Times that go backwards in a trip drop that trip, counted in `stats.dropped`.
- Realtime freshness is whatever PLK publishes; the poll interval is only the upper bound on lag.
- Coverage is through trains between the configured groups. The default station names are guesses.

## Open points to verify at the first live run

1. `unresolved` in `/health` must be empty. Fix names in `config.toml` (the Lesser Poland operator
   code can then be found in the carriers dictionary; no carrier filter is set by default).
2. `realtime.match_ratio` should be near 1 for trains in the static feed. If it is low, the
   `trainOrderId` convention differs from what `gtfs.trip_id` assumes.
3. The spec says `arrivalDay` is an offset; confirm it is relative to the operating date of the
   trimmed section (monotonic-time check drops a trip loudly if not).
4. Whether the hourly window is rolling and when the daily counter resets. The code is conservative
   (Warsaw midnight) and self-corrects from the headers.

## Validation (quality gate)

Run on the fixture-built feed, reports in `reports/`:

- MobilityData GTFS validator 8.0.1 (jar hash verified): 0 errors, 1 warning, 1 info.
  Warning `mixed_case_recommended_field`: `route_long_name` "IC REYMONT" comes from the source
  category and train name in capitals; left as published. Info `unknown_file`: `license.txt` is
  intentional.
- GTFS-RT: the MobilityData realtime validator ships no CLI or offline release (webapp package or
  build from source only), so it was not run. Instead `tests/validate_rt.py` checks the protobuf
  structure and cross-checks the static zip: header, FULL_DATASET, unique IDs, every `trip_id` and
  `start_date` exists in the service calendar, every `stop_id` is on that static trip and in order,
  cancelled trips carry no stop updates, alerts point at real trips. 0 errors on 3 trip updates and
  1 alert. Re-run the official validator against the live feed once it exists.
- 32 unit tests on the fixtures (schema, limiter, client, resolver, geocoder, build, realtime, an
  end-to-end flow): `reports/unit-tests.txt`. Also run in the image with `--network none`.

Fixtures in `tests/fixtures/` are synthetic-from-spec: invented IDs and times, shapes from the
OpenAPI document. Regenerate with `python tests/make_fixtures.py`. Station IDs 9000xx are fake.

## Build and run

```
docker build --target test -t plk-trains-test . && docker run --rm --network none plk-trains-test
docker build -t plk-trains .
```

Base image `python:3.12-slim-bookworm` pinned by index digest (amd64 and arm64), dependencies from
`requirements.txt` with hashes (`gtfs-realtime-bindings`, `protobuf`, `tzdata`). Only the amd64 build
was run here; the arm64 wheels are in the hash list but not built. Non-root user 10001, no secrets
in the image, state in the `/data` volume (breaker, counters, caches, outputs).
