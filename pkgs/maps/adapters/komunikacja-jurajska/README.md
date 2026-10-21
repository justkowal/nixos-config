# komunikacja-jurajska adapter

Turns the passenger information pages of Jurajski Zwiazek Powiatowo-Gminny "Komunikacja Jurajska"
(county buses around Czestochowa), served by kiedyPrzyjedzie.pl, into a static GTFS zip and
GTFS-Realtime (TripUpdates, VehiclePositions) for OpenTripPlanner. Internal Docker network only.
Personal, non-commercial use. The converted feeds are never published or shared.

Status: built and tested on recorded fixtures only. The crawler has never been run against the live
site end to end; only the 32 requests listed under "Requests made while researching" were sent.

## Owner authorization (R1 override), verbatim

The source's `robots.txt` says `User-agent: *` / `Disallow: /` and the operator publishes no GTFS.
The owner decided, in chat:

> "I allow you to still write a scraper for komunikacja-jurajska, I know their robots.txt and i believe that a small fetch that puts similar load that an average user does purely for personal use will do no harm."

So the owner knowingly overrides the robots.txt for personal, non-commercial use at a load comparable
to one ordinary user. That holds only at that load level and only with every rule below enforced in
code. Any technical block (403, 429, captcha, bot challenge, redirect to a block page, a login wall,
a non-JSON body where JSON is expected) stops the source for at least 6 hours. Never worked around.
Nothing is hidden: honest User-Agent, no proxies, no headless browser, no accounts, no cookies.

R1 findings that led here (checked 2026-10-21 in an earlier pass): the main domain's robots.txt is 404,
the operator site's is 404, the `komunikacjajurajska.kiedyprzyjedzie.pl` one is the block above (saved
in `reports/kj.kiedyprzyjedzie.pl-robots.txt`). No terms of use for automated access were found. It
was not re-fetched in this pass.

## What the site offers (found by reading its own JS bundle, R5)

The page is a Vue single-page app. The public bundle (`app.*.js` and its lazy chunks `trip`,
`timetables`, `departures`) names every call it makes. All answer JSON, no key, no cookie.

| Endpoint | Gives | Used for |
|---|---|---|
| `GET /` | HTML with `data-stops-revision` | cache key for the stop list, 1 call per day |
| `GET /stops?rev=N` | all 1252 stops: place id, designator, name, lon and lat (x1e6), station flag | stops.txt, with real coordinates |
| `GET /api/timetables/<placeId>?date=YYYY-MM-DD` | every trip calling at that stop that day: `trip_id`, `index` (position of the stop in the trip), `departure` seconds from service-day midnight, platform | trip discovery and the calendar |
| `GET /api/trip/<tripId>/<index>` | the whole trip: line, headsign, every stop with `HH:MM` and its `index` | trips.txt, stop_times.txt |
| `GET /api/departures?places=a,b,c` | departure boards for several stops in one call: `trip_id`, `trip_index`, `time_diff` (delay), `is_estimated` (live), `canceled`, `trip_execution_id` | TripUpdates |
| `GET /api/trip_execution/<base64(execution id)>/<index>` | live state of one run: GPS `vehicle`, `vehicle_trip_index`, `next_departure_index`, `estimates` (expected arrival `HH:MM` for every remaining stop), `canceled` | VehiclePositions and full-trip TripUpdates |

Seen but not used: `/api/directions/<placeId>`, `/api/timetable/<placeId>/<line>` (a subset of
`/timetables`), `/api/customers`, `/api/announcements` (free text without trip references, so it
cannot become a matching Alert), `/api/departures/<placeId>` (single stop, the multi call replaces it).

Base URL is plain `http://` because that is what the site itself serves and links to; a redirect
would trip the breaker, which is the intended behaviour.

Conditional requests: the API sends no ETag or Last-Modified that could be used (only the HTML start
page has a Last-Modified, and it is the render time). Instead everything is cached: stops by
revision, trips by id forever, timetables by (stop, date).

## How the feeds are made

### Static

IDs are stable across regenerations: `stop_id` = the site's place id (for example
`2303517:2391682`), `route_id` = `line-<line name>`, `trip_id` = the site's numeric trip id,
`service_id` = `svc-<trip_id>`, `stop_sequence` = the site's stop `index`. Trip ids repeat on
consecutive days (the 21 and 22 October timetables carried the same ids), which is what makes a
trip a stable key.

1. Cover stops: `seed_stops` from `config.toml`, plus any stop found by probing. One timetable call
   per (cover stop, date) for a rolling 7 day window.
2. Each trip id seen is fetched once through `/api/trip` and cached. Its `HH:MM` times are anchored on
   the timetable's own seconds value, so after-midnight stops become `24:xx:xx` correctly. If a later
   timetable disagrees with the cached times, the trip is dropped from the cache and fetched again.
3. Probing: a stop that no known trip serves gets up to 3 timetable calls (first weekday, Saturday,
   Sunday of the window), at most `probe_per_day` (40) calls a day. Non-empty means the stop becomes a
   cover stop and its new lines are found. Empty on all three means "probed empty", retried after 30 days.
   Stations first, then by name.
4. `calendar_dates.txt` only (no `calendar.txt`): a trip runs on exactly the dates whose timetable
   listed it. Dates outside the window are unknown, so the feed is a rolling week and the validator
   will always warn about expiry (see Validation).
5. Rebuild: first publish 5 minutes after the first data, then at most every 30 minutes while the
   crawl is still learning, and on the first cycle after Warsaw midnight so the window rolls.
   The zip is deterministic (fixed timestamps), the ETag is a hash of its bytes.
6. `feed_info.txt` carries `feed_version = <first date>-<hash>-cov<percent>`: the suffix is the share
   of the 1252 stops that are either on a known trip or probed empty. Below 100 means the feed is a
   partial crawl. `attributions.txt` and `license.txt` state the source, the personal-use limit, and
   the limits below.

### Realtime

Trips get live data only if they call at a stop in `realtime.priority_stops` (default: Czestochowa
Dworzec Autobusowy, Czestochowa Dworzec PKS, Blachownia Dworzec PKP; edit freely, ids come from
`/stops`). That is the polling design: the site answers per stop or per trip, so there is no
all-vehicles call. Coverage is therefore every trip through the priority stops, not the network.

Per cycle: one `/api/departures?places=...` call for all priority stops, then `trip_execution` for
the soonest estimated trip(s) scheduled within 45 minutes. Rows from the board give a stop-level
delay (`time_diff` minutes x 60) for `is_estimated` rows; `trip_execution` gives the vehicle position
and the expected arrival at every remaining stop, which overrides the board for that trip.

| Mode | Cycle | `trip_execution` calls per cycle | Requests per hour |
|---|---|---|---|
| quiet 23:30 to 04:00 Warsaw | none | none | 0 |
| idle (default) | 300 s | 1 | at most 24 |
| boost | 120 s | 1 | at most 60 (lane cap) |

Boost is for "the owner is looking right now": `GET /boost` on the adapter's port (internal) for 15
minutes, or any front end that calls it. Without a caller the adapter stays idle.

Matching rules, all enforced before anything is published:
- `trip_id` must be in the static feed, the row's stop must equal the static stop at that
  `stop_sequence`, and the trip must be active on the chosen `start_date`.
- `start_date` is today or yesterday in Warsaw, whichever puts the scheduled time at that stop
  closer to now (so a 00:30 stop of a trip that started yesterday gets yesterday), within 14 h.
  `start_date` is always set.
- Anything else is dropped and counted in `/health` under `realtime.stats.unmatched_reasons`. The
  Czestochowa rows in the recorded board are all dropped in the tests because only the Blachownia
  trips are in the fixture feed.
- `FULL_DATASET`. Entries expire after 600 s without an update. Header timestamp = time of the last
  successful poll (the multi-stop board carries no server timestamp).
- No Alerts: the announcements endpoint cannot be tied to trips reliably.

## Rate limits and budget math (R2, R3)

Enforced in `adapter/guard.py`; config can only make it slower, never faster (floors are in code).

| Rule | Value |
|---|---|
| Spacing between any two requests | 5 s minimum + 0 to 3 s random jitter |
| Hourly budget, whole source | 100 (code cap), lanes: static 40, realtime 60 |
| Error backoff | exponential, 30 s doubling to 900 s added to the spacing |
| Run of errors | 5 in a row opens the breaker |
| Ban signals (403, 429, any 3xx, bot or block page, 200 without JSON or without the app marker) | breaker open 6 h, persisted in `/data/guard.json` across restarts |
| Kill switch | file `/data/KILL` or env `KJ_KILL=1` |
| 404 or 5xx | counts as an error and backs off, is not a ban. A rejected trip is retried after a day |

Budget math, order of magnitude (the real network size is unknown until the first live run):

- Bootstrap, once: stops 2 calls, timetables = cover stops K x 7 dates, trips = distinct trip ids T.
  A guess of K = 50 and T = 1000 gives about 1400 calls, which at the 40 per hour static lane is
  about 35 hours. It is resumable and publishes partial results as it goes.
- Steady state per day: 1 start page, about K new-date timetables plus K x 1.5 refreshes
  (`tt_refresh_days = 4` on future dates), at most 40 probes, a handful of new trips: about 150
  calls, 6 per hour.
- Realtime: idle at most 24 per hour for about 19.5 active hours: under 470 a day, 20 per hour on
  average. Together the average is about 26 per hour, one request every 2 to 3 minutes, which is
  less than one person keeping the departures page open (that page refreshes itself).

`/health` shows requests in the last hour per lane against the budget, the breaker state and reason,
status code counts, time since the last successful request, crawl progress and coverage, and
realtime match stats. `503` only while no static feed exists. Logs carry status codes, byte counts,
timings and breaker events, never bodies.

## Failure modes

| What happens | Behaviour |
|---|---|
| Ban signal | breaker 6 h, both static and realtime stop, `/health` status `degraded` with the reason |
| Timeout, 5xx, 404 | backoff, retried; 5 in a row opens the breaker |
| Payload with the wrong shape | rejected, never stored, not a ban; the crawl pauses 5 min and retries |
| Trip times disagree with the timetable | trip dropped from cache and refetched; if still bad it is rejected for a day |
| Site changes `trip_execution` id encoding | executions fail with 400, counted, vehicle positions stop, board delays still flow |
| Adapter restarts | budget, breaker and crawl state are in `/data`, nothing resets |
| Priority stop id wrong | board returns no such block or rows do not match, visible in `unmatched_reasons` |

## What is missing or estimated (R7)

Nothing is invented. Limits:

- Coordinates are the site's own. No stop coordinates are estimated. Nominatim is not used.
- No shapes. No `direction_id` (the site gives only a headsign text per trip).
- Times have one-minute resolution; arrival equals departure at every stop. The site shows no dwell.
- Station stops (6 of them, for example the two Czestochowa bus stations) are plain stops. Platform
  numbers are not exported.
- Coverage of the static feed grows with the crawl; check `static.coverage` and the `cov` suffix.
  A stop that never shows service stays out of stops.txt (only used stops are written).
- Calendar knowledge ends at the 7 day window. Holidays are handled implicitly because the timetable
  is requested per date.
- Realtime covers only trips through the priority stops. Lower freshness by design: up to 5 minutes
  idle for the board, `trip_execution` polled for one trip per cycle.
- Inferred from one recorded sample or from the site's own JS and not yet seen with a non-zero value:
  `time_diff` is in minutes (the sample showed 2 against "8 min" and "5 min", so it is rounded);
  a board row with `canceled` means that stop is cancelled (becomes SKIPPED); the `canceled` list in
  `trip_execution` holds stop indexes (ignored if not integers). The estimate path of
  `trip_execution` was only exercised with zero delay. Re-check these at the first live delay.
- Vehicle position timestamp is the poll time, the site gives none. Vehicle id is not set (the site
  publishes no plate or id).
- `trip_execution` ids are base64 of the execution id as the site does it. A `/` inside the base64
  would break the path, as it does for the site.
- Personal data: none collected. Only stop, trip and aggregate vehicle position data.

## Validation (quality gate)

Run on the feed the crawler builds from the recorded fixtures (19 trips of lines 151 and 105
through Blachownia, 67 stops, 2 dates), reports in `reports/`:

- MobilityData GTFS validator 8.0.1 (jar hash verified, 19293ddd...91000e2): 0 errors, 2 warnings,
  2 infos. `gtfs-validator-8.0.1-report.html` and `.json`.
  - `feed_expiration_date7_days` (warning): the fixture covers 2 days; in production the rolling
    window is 7 days, which the same rule flags by design. Accepted: the feed is regenerated daily
    and the source does not publish further.
  - `trip_coverage_not_active_for_next7_days` (warning): same cause, the fixture has two dates.
  - `trip_headsign_matches_intermediate_stop` (info): trip 37634172 (line 105) has the headsign
    "Aleksandria skrz I" and also passes a stop of that name at sequence 23. Left as published.
  - `unknown_file` (info): `license.txt` is intentional.
- GTFS-RT: the MobilityData realtime validator has no offline release, so `tests/validate_rt.py`
  checks the protobuf structure with `gtfs-realtime-bindings` and cross-checks the static zip:
  header, FULL_DATASET, unique entity ids, every `trip_id`, `route_id`, `start_date` and `stop_id`
  attaches to the right static trip and sequence. 0 failures on 3 trip updates and 1 vehicle position
  (`reports/gtfs-rt-structural-check.txt`). Re-run the official validator on the live feed later.
- 32 unit tests on recorded fixtures (guard floors and breaker, a loopback HTTP server for ban
  signals and the honest User-Agent, parsers, the crawl to completion, probe cap, GTFS build and
  determinism, RT matching and expiry, HTTP endpoints). `reports/unit-tests.txt`. Also run in the
  image with `--network none`.

Fixtures in `tests/fixtures/` are recordings from 2026-10-21 of the calls listed above. They contain
public timetable data only; no cookies, tokens or personal data were present, so nothing needed
redacting beyond dropping unrelated stops from `stops.json`.

## Requests made while researching

32 requests to `komunikacjajurajska.kiedyprzyjedzie.pl`, all GET, spaced at least 6 s, honest
User-Agent, no errors except two self-inflicted wrong-shape probes (a 404 for guessing a stop id by
designator and a 400 for an unencoded execution id), no block signal of any kind:

start page 1, JS bundle and three lazy chunks 4, `/stops` 1, `/api/departures` 3 (one 404),
`/api/trip` 19, `/api/trip_execution` 2 (one 400), `/api/timetables` 2.

## Build and run

```
docker build --target test -t kj-adapter-test . && docker run --rm --network none kj-adapter-test
docker build -t kj-adapter .
```

Base image `python:3.12-slim-bookworm` pinned by the same index digest as the sibling adapters;
dependencies from `requirements.txt` with hashes (`gtfs-realtime-bindings`, `protobuf`, `tzdata`).
Only amd64 was built here; the arm64 wheels are in the hash list. Non-root uid 10001, state in the
`/data` volume (`state.json`, `guard.json`, `gtfs.zip`), no secrets anywhere. Port 8080.

| URL | Content |
|---|---|
| `/gtfs/komunikacja-jurajska.zip` | static feed, ETag |
| `/gtfs-rt/trip-updates.pb` | TripUpdates, 503 until the first poll |
| `/gtfs-rt/vehicle-positions.pb` | VehiclePositions |
| `/health` | see above |
| `/boost` | switch realtime to the fast cycle for 15 minutes |

Editing `config.toml` (mount over `/app/config.toml`): `seed_stops` and `priority_stops` are the main
knobs. Rate limits below the code floors are ignored.
