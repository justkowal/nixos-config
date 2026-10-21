# komunikacja-jurajska adapter

Static GTFS and GTFS-Realtime (TripUpdates, VehiclePositions) for Jurajski Zwiazek Powiatowo-Gminny
"Komunikacja Jurajska" (county buses around Czestochowa), for OpenTripPlanner. Internal Docker network
only. Personal, non-commercial use. The converted feeds are never published or shared.

- **Timetables and stop positions** come from the operator's own site, www.komunikacjajurajska.pl
  (plain HTML, one page per line).
- **Live data** comes from komunikacjajurajska.kiedyprzyjedzie.pl (the operator's passenger-information
  service, a JSON API behind a Vue app). It is also used to compare stop positions and to say per line
  whether live data is possible.

Status: built and tested on recorded fixtures. The crawler has never run end to end against the live
sites. The full line set was fetched once by hand with the same parsers (see "Requests made") and the
resulting feed passes the validator.

## Owner authorization (R1 override), verbatim

The kiedyPrzyjedzie subdomain's `robots.txt` says `User-agent: *` / `Disallow: /` and the operator
publishes no GTFS. The owner decided, in chat:

> "I allow you to still write a scraper for komunikacja-jurajska, I know their robots.txt and i believe that a small fetch that puts similar load that an average user does purely for personal use will do no harm."

and later: "ensure the kiedyprzyjedzie adapter covers all lines and stops, static schedules available at
https://www.komunikacjajurajska.pl/".

So the owner knowingly overrides the robots.txt for personal, non-commercial use at a load comparable
to one ordinary user. That holds only at that load level and only with every rule below enforced in
code. Any technical block (403, 429, captcha, bot challenge, redirect to a block page, a login wall, a
non-JSON body where JSON is expected) stops that source for at least 6 hours. Never worked around.
Honest User-Agent `kowal-lab-maps-adapter/0.1 (personal use; contact hopkuba@gmail.com)`, no proxies, no
headless browser, no accounts, no cookies.

Operator site, re-checked 2026-10-21 (`reports/komunikacjajurajska.pl-robots-check.txt`): `/robots.txt`
answers 200 with the site's "page not found" template, no rules at all. No terms of use for automated
access, only a privacy policy link and a cookie banner. Pages are public, no login.

## Where the data comes from

### Operator site (primary for static)

| Page | Gives | Calls |
|---|---|---|
| `GET /` | links to every line page (52 lines) | 1 per day |
| `GET /linia-nr-<line>-i<id>.html` | the line's timetable for both directions as HTML tables (one row per stop, one column per course, grouped Monday-Friday / Saturday / Sunday and holidays), the validity period (`od ... do ...`), a legend for course symbols, and a Leaflet script with one `L.marker` per stop of one direction: position, operator stop id, stop name | 1 per line, every 3 days |
| the page's "zawroc" link (`b_odwroc`) | the same for the opposite direction, so the other direction's stop ids and positions | 1 per two-way line, every 3 days |

`mapa-przystankow.html` (the stop map) was read once. It shows 208 stops of its default selection with
the same ids and positions as the line pages (0 m difference for all 208), so it adds nothing and is not
used. PDFs are not needed: the HTML tables are complete, so no PDF tooling is in the image.

Pages carry `Cache-Control: no-store` and no validators, so there is nothing to make conditional
requests with. Re-reading is bounded by `line_refresh_days = 3` and the start page check once a day.

### kiedyPrzyjedzie (live data, comparison, census)

| Endpoint | Used for |
|---|---|
| `GET /` and `GET /stops?rev=N` | all 1252 stops with positions, once per revision, checked daily; position comparison and name matching |
| `GET /api/timetable/<place>/<base64url(line)>?date=` | census: does kiedyPrzyjedzie serve this line (a 404 means unknown line), once per line, repeated monthly |
| `GET /api/departures?places=a,b,c` | live board for the priority stops, one call per cycle |
| `GET /api/trip/<id>/<index>` | one call per live trip and day type, only to match it to an operator trip (see below), cached |
| `GET /api/trip_execution/<base64(execution id)>/<index>` | vehicle position and expected arrival at every remaining stop |

Not used: `/api/timetables/<place>` and the per-trip crawl of the first version. The operator pages
make the slow discovery crawl unnecessary (the old design needed an estimated 1400 requests, about 35
hours).

## The static feed

Run on the full set of real pages (analysis run, same code as the crawler): **52 of 52 lines on the
site, 2048 trips, 1358 stops, 52 routes**. The site's start page lists 52 line pages: the 51 lines on
the owner's screenshot plus line 123B. No line is missing. No other group appears on the start page.

- `route_id = line-<line>`, `stop_id` = the operator's stop id (for example `1674`),
  `trip_id = <line>-<A|B>-<wd|sa|su>-<HHMM of the first departure>` (a `-2` suffix on collisions),
  `stop_sequence` = the stop's row in the operator table. Direction A is the line page's own first
  direction, B its reverse page. These ids do not depend on the operator's course numbers, so adding
  a course does not renumber the others.
- Calendar: `calendar.txt` with one service per (day type, validity period): Monday-Friday,
  Saturday, Sunday. `calendar_dates.txt` moves Polish public holidays to the Sunday service (computed in
  `adapter/calpl.py`: fixed dates, Easter Monday, Pentecost, Corpus Christi, 24 December from 2025).
  The operator labels its third column "Niedziela i swieta"; applying it to a holiday that falls on a
  weekday is the natural reading but is an inference.
- Validity: each line's `od ... do ...` from its page (all end 2026-12-31 today). The feed's end date is the latest period end,
  so it expires 2026-12-31 until the operator publishes more.
  A timetable whose period has ended is not published and is listed in `/health`.
- A course is one column of the table. Cells reading `<<` (the course does not call there) or empty are
  skipped. Trips need at least two timed stops. Times are `HH:MM`, arrival equals departure,
  after-midnight stops continue past 24:00:00.
- Headsign = the last stop of the course (derived, the page gives only a direction title per table,
  which goes into `route_long_name`). Route type 3. Single agency, the organiser.
- Course symbols: the legend on each page is parsed. Most mean a route variant ("kurs skrocony do ...")
  and need nothing. `S` ("kursuje w dni nauki szkolnej") and `H` ("kursuje w dni wolne od nauki
  szkolnej") depend on the school calendar, which is not published there, so those trips are present on
  every day of their day type. All symbols go into `trip_short_name`. 127 trips are S or H trips, listed
  per line below.

### Stop positions and reconciliation

Positions come from the operator's Leaflet markers (`reports/stops-reconciliation.txt` has the lists).
The stop ids in the markers are the operator's own ids and are consistent across lines.

Compared by normalised name with the nearest same-name stop in kiedyPrzyjedzie:

| | Stops |
|---|---|
| Operator stops with a position | 1368 (1358 used by a trip) |
| agree within 30 m | 969 |
| 30 to 100 m | 119 |
| over 100 m | 73 |
| only on the operator map (no same-name stop on kiedyPrzyjedzie) | 207 |
| kiedyPrzyjedzie stop names no operator timetable serves | 68 |

Source per stop in the feed: operator map for 1345, kiedyPrzyjedzie for 13. Rule: where the operator
marker is more than 1000 m from every same-name kiedyPrzyjedzie stop, the kiedyPrzyjedzie position is
used and `stop_desc` says so. These 13 are clear marker errors on the operator side: Borowce I (36.5
km), Rogaczew (33 km), Wancerzow Kosciol (12.9 km), Jaskrow Mirowska (7.7 km), Czestochowa Sw. Rocha
Szkola (4.3 km), Pila Druga (2.6 and 1.9 km), Paulinow (1.8 km), Naklo Stacja Paliw (1.4 km). The
validator's travel-speed check confirms it: before the rule 302 consecutive-stop warnings, after it 32.

Left as published, listed in the same report: the 60 stops between 100 m and 1 km off (names are
shared by posts on both sides of a road or the villages' stops differ), and the 207 operator-only
stops that have no second source. The speed warnings that remain all come from one operator marker,
stop 743 "Czestochowa, Goździków" (line 117), about 8 km from its neighbours with no second position to
correct it. No coordinate was invented, geocoded or taken from a map service.

### Per-line coverage

Also in `reports/line-coverage.md` and in `/health` (`static.lines`). "Known to kiedyPrzyjedzie" is the
census result for the line's first stop on the next day of its first day type, so "no" means no trip
found there, which can be a false negative (the matching stop may be named differently or served by
the other post). Live data is only possible for lines marked yes.

| Line | Trips in feed | Stops in feed | Day types | S or H trips | Known to kiedyPrzyjedzie | Status |
|---|---|---|---|---|---|---|
| 101 | 87 | 53 | sa/su/wd | 1 | no | ok |
| 102 | 73 | 58 | sa/su/wd | 1 | no | ok |
| 103 | 24 | 40 | wd | 1 | no | ok |
| 104 | 78 | 72 | sa/su/wd | 0 | no | ok |
| 105 | 91 | 55 | sa/su/wd | 0 | yes | ok |
| 111 | 64 | 64 | sa/su/wd | 2 | yes | ok |
| 112 | 54 | 69 | sa/su/wd | 4 | yes | ok |
| 113 | 14 | 63 | wd | 0 | yes | ok |
| 114 | 88 | 56 | sa/su/wd | 0 | yes | ok |
| 115 | 54 | 92 | sa/su/wd | 0 | yes | ok |
| 116 | 57 | 99 | sa/su/wd | 0 | yes | ok |
| 117 | 31 | 59 | sa/wd | 6 | yes | ok |
| 118 | 60 | 63 | sa/su/wd | 0 | yes | ok |
| 119 | 10 | 68 | wd | 10 | yes | ok |
| 121 | 18 | 61 | wd | 0 | yes | ok |
| 122 | 19 | 43 | wd | 0 | yes | ok |
| 123 | 56 | 52 | sa/su/wd | 4 | no | ok |
| 123B | 7 | 28 | wd | 7 | no (no same-name stop found) | ok |
| 125 | 51 | 59 | sa/su/wd | 2 | no | ok |
| 126 | 53 | 57 | sa/su/wd | 0 | yes | ok |
| 130 | 86 | 65 | sa/su/wd | 0 | yes | ok |
| 131 | 36 | 11 | sa/su/wd | 0 | yes | ok, one-way |
| 132 | 16 | 34 | wd | 0 | yes | ok |
| 141 | 22 | 31 | sa/wd | 0 | yes | partial, see below |
| 142 | 16 | 38 | sa/wd | 0 | yes | ok |
| 143 | 8 | 66 | wd | 0 | yes | ok |
| 151 | 62 | 71 | sa/su/wd | 0 | yes | ok |
| 153 | 108 | 70 | sa/su/wd | 2 | yes | ok |
| 154 | 73 | 102 | sa/su/wd | 5 | no | ok |
| 155 | 27 | 46 | sa/wd | 3 | yes | ok |
| 157 | 76 | 73 | sa/su/wd | 3 | no | ok |
| 158 | 56 | 61 | sa/su/wd | 0 | yes | ok |
| 159 | 14 | 53 | wd | 0 | yes | ok |
| 164 | 41 | 53 | sa/su/wd | 0 | no | ok |
| 165 | 80 | 95 | sa/su/wd | 8 | yes | ok |
| 166 | 43 | 78 | sa/wd | 25 | no | ok |
| 168 | 98 | 71 | sa/su/wd | 0 | yes | ok |
| 169 | 13 | 61 | wd | 0 | no | ok |
| 170 | 58 | 67 | sa/su/wd | 0 | yes | ok |
| 175 | 52 | 73 | sa/su/wd | 0 | yes | ok |
| 501 | 4 | 9 | wd | 4 | yes | ok, one-way |
| 502 | 3 | 10 | wd | 3 | yes | ok, one-way |
| 503 | 4 | 22 | wd | 4 | yes | ok, one-way |
| 504 | 7 | 31 | wd | 7 | yes | partial, see below |
| 505 | 10 | 16 | wd | 10 | yes | ok |
| 506 | 6 | 26 | wd | 6 | yes | ok |
| 530 | 3 | 22 | wd | 3 | yes | ok, one-way |
| 531 | 6 | 26 | wd | 6 | no | ok, one-way |
| 551 | 5 | 11 | wd | 0 | no | ok, one-way |
| 552 | 5 | 23 | wd | 0 | no | ok |
| 553 | 11 | 28 | wd | 0 | no | ok |
| 554 | 10 | 19 | wd | 0 | no | ok |
| **total** | **2048** | **1358 distinct** | | **127** | **35 of 52 lines** | |

"One-way" means the operator page has a single direction table and no reverse page. The other 45
lines have two directions, and for each the reverse page's table was checked against the first page's
return table: all 45 agree.

Partial lines, and why:
- **141**: three rows at the end of the return table (stops 22 to 24) have 6 cells for 11 courses in
  the source HTML. The cells are read as "does not call" for the missing courses, which is the natural
  reading but unverified. The affected trips lose those last stops.
- **504**: three rows at the end of the return table have no cells at all, so those stops get no times
  for that direction.
- **17 lines are not known to kiedyPrzyjedzie** (101, 102, 103, 104, 123, 123B, 125, 154, 157, 164,
  166, 169, 531, 551 to 554). They are in the static feed but cannot get live data from this source.

## The realtime feed and how it attaches to the operator ids

The two sources share no ids, so a live trip is attached by content, once per (kiedyPrzyjedzie trip id,
day type), and cached in `/data/state.json`:

1. A board row carries a kiedyPrzyjedzie `trip_id`, `trip_index`, and the stop. One `/api/trip` call
   returns that trip's line and its stops with names and `HH:MM`.
2. Candidates are the operator trips of the same line and day type of the date being matched. The score
   is the share of (normalised stop name, minute) pairs the two trips have in common, relative to the
   shorter list. A match needs at least 0.8 and a unique best. The live `trip_index` is then translated to
   the operator `stop_sequence` through the shared pairs.
3. The trip is attached only if it is active on the chosen `start_date` in the static calendar, and the
   board's stop name equals the operator stop name at that sequence. Anything else is dropped and
   counted under `realtime.stats.unmatched_reasons` in `/health`.

Test on the 19 real kiedyPrzyjedzie trips of lines 151 and 105 recorded earlier: all 19 matched an
operator trip, each sharing nearly all its stops (36 of 37 for the 151 example). For example live trip 38155603 is operator trip
`151-B-wd-0830`.

`start_date` is today or yesterday in Warsaw, whichever puts the scheduled time at the matched stop
closer to now (within 14 h), and always set. TripUpdates carry `trip_id`, `route_id` and `start_date`
of the operator feed and `stop_sequence` plus `stop_id` of the operator feed. VehiclePositions likewise.
`FULL_DATASET`; entries expire after 600 s. Header timestamp is the last successful poll. No Alerts.

Polling is restricted as before to `realtime.priority_stops` (default Czestochowa Dworzec
Autobusowy, Dworzec PKS, Blachownia Dworzec PKP):

| Mode | Cycle | Requests per hour |
|---|---|---|
| quiet 23:30 to 04:00 Warsaw | none | 0 |
| idle | 300 s: 1 board call, up to 1 `trip_execution`, up to 3 one-off mapping calls | at most 60 (lane cap), typically 24 |
| boost (`GET /boost`, 15 min) | 120 s, 1 `trip_execution` | at most 60 |

Warm-up: every distinct live trip needs one mapping call per day type, then it is cached. The first
few days the rows for trips not mapped yet are skipped and counted, coverage grows as the cache fills.

## Rate limits and budget (R2, R3)

Per source, separate guards, state files and breakers (`/data/guard-op.json`, `/data/guard-kp.json`).
Enforced in `adapter/guard.py`; config can only slow it down.

| Rule | Value |
|---|---|
| Spacing between two requests to one source | 5 s minimum + 0 to 3 s random jitter |
| Hourly budget | 100 per source (code cap); operator: static lane 60; kiedyPrzyjedzie: static lane 20, realtime lane 60 |
| Error backoff | exponential, 30 s doubling to 900 s added to the spacing; 5 errors in a row open the breaker |
| Ban signals (403, 429, any 3xx, a challenge page such as "Just a moment", 200 without JSON or without the app marker) | breaker open 6 h, persisted |
| Kill switch | `/data/KILL` or `KJ_KILL=1` |
| Soft 404 | only the census treats a 404 as an answer ("line unknown"), everywhere else 404 is an error |

The operator pages contain the word "captcha" (a contact form), so for HTML pages only challenge-page
phrases count as a block, not that word.

Budget math:
- Bootstrap, once: operator 1 + 52 + 45 = 98 page loads (about 100 minutes at the 60 per hour lane,
  12 minutes if the lane were unlimited); kiedyPrzyjedzie 2 + 52 census calls (about 3 hours at the
  20 per hour lane). Resumable.
- Steady state per day: operator start page 1 + line pages 97 / 3 days = about 33; kiedyPrzyjedzie stop
  check 1 + census 52 / 30 days = about 3. So about 37 static requests a day, 1.5 per hour.
- Realtime: at most 24 per hour idle plus mapping during warm-up, under 600 a day. Average load is a
  request every 2 to 3 minutes while the feeds are in use, less than one person with the departures
  page open (it refreshes itself).

## Failure modes

| What happens | Behaviour |
|---|---|
| Ban signal on either source | that source's breaker opens for 6 h, its half of the adapter pauses, `/health` is `degraded` with the reason; the other source keeps its own state |
| Timeout, 5xx, 404 | backoff; 5 in a row open the breaker |
| A line page without a timetable or validity period | rejected, not stored, retried after 6 h, the previous record stays |
| Operator removes a line | dropped from the feed at the next start page check |
| Marker list does not line up with the table | the line is published without ids for that direction's stops, so those stops are resolved by name or dropped; reported as a problem in `/health` |
| Stop without an operator id or position | resolved by an unambiguous same-name stop, else dropped from its trips and counted (`dropped_stops`) |
| Timetable period over | the line is not published and appears with that status |
| Restart | budgets, breakers, crawl state and the trip mapping are in `/data` |

## What is estimated or missing (R7)

- All timetable data and almost all positions are the operator's. Estimated or inferred: Polish holiday
  dates (computed), the headsign (last stop), holidays using the Sunday service, S and H trips
  running on every day of their type, missing cells in 141 and 504 read as "not calling", the
  rule that moves 13 positions to kiedyPrzyjedzie.
- One-minute time resolution, no shapes, no `direction_id`, no platforms.
- 17 lines have no live data source. Realtime covers only trips through the priority stops.
- Not yet seen with a non-zero value, from one recorded sample and the site's JS: `time_diff` is minutes;
  a cancelled board row means that stop is cancelled; the `canceled` list of `trip_execution` holds
  stop indexes. Re-check at the first live delay. The vehicle timestamp is the poll time.
- Carrier per line ("Za realizacje rozkladu odpowiada ...") is on the pages but not exported.
- The census "no" can be a false negative, see above.
- Personal data: none collected.

## Validation (quality gate)

- MobilityData GTFS validator 8.0.1 (jar hash verified, 19293ddd...91000e2) on the full feed above:
  **0 errors**, 2 warnings, 2 infos (`reports/gtfs-validator-8.0.1-report.html` and `.json`).
  - `fast_travel_between_consecutive_stops` (32) and `fast_travel_between_far_stops` (16): all involve
    stops 537, 58 and 743 on line 117, of which 743 is an operator marker about 8 km from its
    neighbours, with no second position to replace it. Left as published and listed above.
  - `trip_headsign_matches_intermediate_stop` (8, info): loop courses that pass a stop named like their
    last stop.
  - `unknown_file` (info): `license.txt` is intentional.
- GTFS-RT: no offline release of the MobilityData validator, so `tests/validate_rt.py` checks structure
  with `gtfs-realtime-bindings` and attaches every `trip_id`, `route_id`, `start_date`, `stop_id` and
  `stop_sequence` against the static zip: 0 failures on 3 trip updates and 1 vehicle position
  (`reports/gtfs-rt-structural-check.txt`).
- 53 unit tests on recorded fixtures only (`reports/unit-tests.txt`), also run in the image with
  `--network none`: guard floors, two independent breakers, ban signals over a loopback server, the
  honest User-Agent, operator parsers (tables, symbols, short rows, one-way, reverse cross-check),
  holidays, crawl request counts, stale refetching, GTFS content and determinism, position reconciliation
  and override, live-to-operator mapping, TripUpdate and VehiclePosition output, endpoints.

Fixtures in `tests/fixtures/`: `op/` has five slimmed operator pages (lines 151, 102, 131, 141, 123B and
a start page with those five links: tables, validity, legend, map markers kept, the rest of the page
dropped), the kiedyPrzyjedzie files are recordings of the calls above, with `stops.json` reduced to the
stops the tests need. No cookies, tokens or personal data are in them.

## Requests made while researching (live)

Operator site: **143 requests** (100 distinct): `/robots.txt` 1, start page 1, line pages 52, reverse
pages 45, stop map 1. 43 of them were duplicates of line pages. Cause, my error: a first batch run was
still going when I started a second one, so for a few minutes two clients ran at once and the spacing
between requests was shorter than the 5 s rule, roughly 3 s on average. All answered 200. No 403, 429,
challenge, redirect or slowdown was seen. The adapter itself cannot do this, its guard serialises
requests, spacing is enforced per source in one place.

kiedyPrzyjedzie: **85 requests** over the whole task. 32 earlier (start page, JS bundle and chunks,
stop list, boards, trips, timetables) plus 2 probes of the per-line timetable and 51 census calls made
through the adapter's own guard (46 lines answered, 5 answered 404 meaning "line unknown"). No block
signal.

## Build and run

```
docker build --target test -t kj-adapter-test . && docker run --rm --network none kj-adapter-test
docker build -t kj-adapter .
```

Base image `python:3.12-slim-bookworm` pinned by the same index digest as the sibling adapters;
dependencies from `requirements.txt` with hashes (`gtfs-realtime-bindings`, `protobuf`, `tzdata`). Only
amd64 was built here. Non-root uid 10001, state in the `/data` volume (`state.json`, `guard-op.json`,
`guard-kp.json`, `gtfs.zip`), no secrets anywhere. Port 8080.

| URL | Content |
|---|---|
| `/gtfs/komunikacja-jurajska.zip` | static feed, ETag |
| `/gtfs-rt/trip-updates.pb` | TripUpdates, 503 until the first poll |
| `/gtfs-rt/vehicle-positions.pb` | VehiclePositions |
| `/health` | both guards, per-line table, position comparison counts, crawl and realtime state |
| `/boost` | switch realtime to the fast cycle for 15 minutes |

Config (`config.toml`, mount over `/app/config.toml`): the two base URLs, per-source limits,
`line_refresh_days`, and `priority_stops`.
