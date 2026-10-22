# Kowal Nav (navigation web app)

Personal door to door navigation across every operator in the routing graph (see `MAPS.md`), as an installable PWA: `https://nav.23012006.xyz`.
It uses the same Nominatim and OpenTripPlanner as the MCP `osm` and `routing` servers, so a feed added to the registry shows up in both.

Source: `pkgs/nav/` (server `server.py`, client `static/`), module `hosts/rpi4/nav.nix`. Container `lab-nav` reuses the gateway image, the code is mounted read-only from the store.
Route: cloudflared `*.23012006.xyz` -> Traefik -> label `Host(nav.23012006.xyz)`. No host port, no tunnel change.

## Access and secrets

One passphrase, `NAV_SECRET` in `/var/lib/mcp-gateway/nav.env` (the container does not start without that file). Create it on the Pi:

```bash
sudo sh -c 'umask 077; printf "NAV_SECRET=%s\n" "$(openssl rand -base64 24 | tr -d "=+/")" > /var/lib/mcp-gateway/nav.env'
sudo cat /var/lib/mcp-gateway/nav.env   # copy the value into your password manager, then: sudo systemctl restart podman-lab-nav
```

- Login exchanges the passphrase for a signed token: an HttpOnly, Secure, SameSite=Strict cookie for the web app (90 days), or a bearer token for a named device (365 days, see below).
- 5 wrong passphrases per 15 minutes per client address lock that address out. API calls are limited to 90 a minute per address, Traefik adds its own limit.
- Rotating `NAV_SECRET` signs everyone out. The API is read only except the watch and push registration tables for the signed-in device.
- The server logs no request lines (they would contain coordinates) and the page loads no third-party script. The only third party is the tile host (below).

## Data and attribution

- Tiles: OpenFreeMap (`tiles.openfreemap.org`, no key, free, attribution shown on the map). The tile host sees which area you look at. Allowed in the page CSP only for images and connections.
- Geocoding, routing, stops, departures: local Nominatim and OTP.
- Operator colours: `static/providers.json`. The values are approximations, edit them freely (first entry whose `match` is found in the agency name wins).
- Times shown as live come from the GTFS-RT updaters in the graph. A vehicle without live data is labelled "No live data" (hollow dot) and shows the timetable time. Delays above 2 hours are treated as wrong-day updates and hidden (ZTP night lines).

## Features

- Search with local autocomplete, recent places (clearable), long press on the map for "From here" or "To here", share state in the URL hash.
- Mode picker (transit, walk, bike, car), transit type filter (train, bus, tram), leave at or arrive by, and Advanced menu for per-mode transfer headroom (e.g. minimum 10 min buffer when transferring to a train, remembered on device and in URL hash).
- Results as a journey ribbon, detail with every leg, transfer buffer at platforms, intermediate stops, live status per leg, stop departures (auto refresh every 30 s).
- Live guidance (Start button): GPS follow with heading, next maneuver or boarding, stops remaining, get-off prompt, wake lock, optional voice, vibration.
  - Off route (more than 40 m walking, 60 m driving, 130 m on a vehicle, three fixes in a row) replans from the current position.
  - Every 45 s live times of the trips ahead are refreshed. If a vehicle will be missed, or the projected arrival is more than 5 minutes after the planned one, it searches for a way to arrive by the original arrival time and switches when the new plan arrives 3 or more minutes earlier (or the old one is no longer possible). While on a vehicle the new plan starts at the get-off stop.
  - `#sim=1` in the URL replays the route as fake GPS fixes for testing.
- Limits of a web app: geolocation pauses when the page is not in the foreground, so guidance needs the screen on (a wake lock is requested). Notifications while the app is closed need Web Push, see below.

## Live vehicles

Default view with no route: every vehicle that has live data, in three levels of detail (`static/vehicles.js`).
- **Far (below zoom 11.8):** a heatmap of all vehicles in view, from compact positions only (`/api/v1/vehicles?lod=heat`).
- **Middle (zoom 10.4 to 16.2):** one dot per vehicle in its operator colour with the line number, tap for line, destination, operator and next stop.
- **Close (zoom 15.3 and up):** painted 3D models. Buses are one body, trams are three articulated cars with bellows, trains are three cars (Intercity: two coaches and a locomotive). Cars sit on the track at their own distance, so they bend through curves. Paint comes from the `livery` of the operator in `static/providers.json` (per mode where an operator differs, e.g. GZM yellow buses and red trams). `confirmed: false` entries are guesses, edit them. Confirmed from press and the city identity guide: Kraków white with dark blue (new or refurbished vehicles, the fleet is mixed), GZM yellow buses, red trams, yellow-green trolleybuses.
- Click or tap a dot or a 3D model to follow that vehicle: the camera glides after it (and in 3D turns to look along its direction), a bar shows line, destination, operator and next stop, and "Stop" or dragging the map ends it.
- In a route's detail: every stage has a pin button that highlights that leg on the map and in the list; stops in "N stops" and the walking directions are clickable and fly to their place; the "Live" badge of a transit leg is a button that finds that trip's vehicle and follows it. A live departure in a stop's list does the same.
- With a route or navigation active, its vehicles get a ring and the others dim.
- Buttons on the map: vehicles on/off, 3D (tilts the map to 58 degrees, enables rotation, shows 3D buildings from the vector tiles, and the same tilt is used while navigating).

How a vehicle moves between reports (the feed delivers positions every 10 to 120 s, GZM gives no speed or heading):
- The server returns the trip's shape with the position of every stop and every traffic signal along it (`/api/v1/shape?trip=`, cached 6 h). Signals come from OSM (`highway=traffic_signals`, `crossing=traffic_signals`), extracted by `build-graph.sh` into `signals.json` and published by graph-watch next to the manifest. Without that file the app animates without lights.
- Each vehicle is dead-reckoned along its shape with a speed controller: it brakes smoothly for a red light (a deterministic phase per junction) and holds until green, docks at the platform when the feed says it is stopped at a stop, and steers back toward the reported position (speeds up when behind, eases when ahead, never reverses). A mismatch of 350 to 600 m is closed with a capped glide, more than 600 m fades the vehicle out, moves it and fades it in. Vehicles with no news for 4 minutes come to rest and dim, after 15 minutes they are dropped. Light stops are only simulated while the vehicle is less than 110 m behind its reported position, so a simulated stop never turns into a lasting lag.
- Controller tests: `node --test pkgs/nav/tests/vehicles.test.js` (fake clock: tracking, red light and catch-up, both mismatch cases, stopped vehicles, stale vehicles, models).

## Explore (general maps)

The default tab. Automatically displays nearby POIs around the map centre or current location (markers on the map and places in the sheet). Search places and addresses (local Nominatim), filter categories around the map centre (All, food, cafes, bars, groceries, pharmacies, health, fuel and charging, ATMs, parking, toilets, hotels, sights, parks, shops) from the OSM data in the local database, tap a marker or a map point of interest, and open its card.
- The card: name, category, address, open now (from OSM `opening_hours`, common syntax only, otherwise the raw text), phone, website, accessibility, cuisine, payment and diet attributes, a link to view or edit the place on OpenStreetMap, Directions (sets the destination and opens Plan), Save (stored on the server, shared by every browser you are signed in on), Share.
- Descriptions and photos: Wikipedia (the `wikipedia` tag, or the article linked from `wikidata`) and Wikimedia Commons, fetched by the server and cached, so the browser never talks to Wikimedia (images go through `/api/img`, restricted to Wikimedia hosts). Attribution and licence are shown under the text.
- Reviews: there is no large open review corpus. Open reviews come from Mangrove Reviews where a place has any (very few in Poland); Google, Yelp and TripAdvisor data are proprietary and not used. You can rate a place 1 to 5 and keep a private note, stored on this server (`notes` table), not published anywhere.
- Live vehicles are not shown in Explore, only in transit contexts (Plan in transit mode, Stops, following a vehicle, diorama).

## 3D renderer, daylight and diorama mode

`static/scene3d.js` is one MapLibre custom WebGL2 layer that draws everything dynamic with instancing: low-poly meshes built once (bus, tram car, rail car, locomotive, bellows) with per-vertex part ids so one palette uniform paints every operator's livery, GPU point sprites for the middle zoom levels and a text atlas for line numbers. Per frame the CPU writes one small typed array per batch (20 bytes per instance, positions as metre offsets from a per-frame origin) and issues a handful of draw calls; nothing is rebuilt per frame. The simulation (`vehicles.js`) does not allocate in its hot path (shapes hold mercator coordinates and unit directions, segment cursors, per-signal cycle tables): about 0.3 ms per frame for 700 vehicles in Node, benchmarked in `tests/vehicles.test.js`.

Extending it (street lights, trees, benches, traffic): build a mesh with `MeshBuilder`, `scene.registerMesh(name, mesh)`, then `scene.addBatch(name, mesh, capacity)` and fill the `InstanceBatch` each frame (moving things) or once (static things). Emissive parts already glow with the night factor.

Diorama mode (the expand button on the map, or `#diorama` in the URL): all controls disappear, vehicles run regardless of context, the map tilts to 3D, and a bar (time, date, Now, Sunrise, Noon, Sunset, Play, Orbit, Exit) fades after 4 seconds of inactivity. Daylight is only active in diorama mode, so the ordinary map keeps a neutral light. The sun position is computed for the real date and place (`static/daylight.js`, tested against textbook values), sunrise, sunset and civil twilight are found by scanning the chosen day, so the cycle follows the actual day length of any date. It drives the vehicle shader, MapLibre's own light for the 3D buildings, the sky and fog, lamps and windows (night factor), and switches the dark base map on at dusk. Esc or Exit leaves the mode.

### Diorama life: traffic, timetable vehicles, roofs

- **Ambient traffic** (`static/traffic.js`): lanes come from the vector tiles' `transportation` layer (one per direction, shifted to the right of travel). Density per road class follows a time-of-day curve (rush hours, midday plateau, quiet night) scaled by 1.6 so it reads as busy. Vehicles use the Intelligent Driver Model, so they queue and never overlap. Five road meshes (hatch, sedan, SUV, van, truck) are tinted any colour via `Fleet.randomColor`. Known limits: lanes do not interact at junctions, and there are no traffic lights for cars.
- **Timetable vehicles** (`static/sched.js`, `/api/sched`): trips running near the view that have no live position are played back from the timetable (ease out of and into each stop, dwell in between). At "Now" the live feed wins and only trips without a position are added. When the time or date is scrubbed, the live feed cannot describe that moment, so live vehicles are hidden and the schedule for that time is shown (`all=1`). Cycle (Play) mode hides them, the clock runs about 1000 times too fast for them to make sense.
- **Street details** (`static/world.js`): trees (round, conifer, bare in winter, leaf colours by month, from park polygons and along streets), street lamps, benches, bins and bus stop shelters with roofs, placed on the traffic lanes and kept off buildings and carriageways (a 3 m grid for buildings, 1 m for roads). Everything is instanced; nothing is drawn below zoom 16.
- **Light cones** (night only): an additive, depth-tested "beam" pass in `scene3d.js` draws cones from street lamps down to a pool on the road, and headlight and tail light cones on every vehicle, live, timetable or ambient. Meshes carry the intensity in the part slot, colour and strength come from the instance.
- **Terrain** (`static/dem.js`, `/api/dem`): the Terrarium DEM (AWS open data) is proxied by the server and used twice: MapLibre drapes the map and buildings on it (`setTerrain`, plus a hillshade lit from the sun's azimuth, zoom 16 and below), and `DemLib.Dem` decodes the same tiles so every instance gets a ground elevation (`z` in the instance, dot and label buffers; roofs bake it into their vertices). The two agree to about 0.2 m. The Terrain chip in the diorama bar cycles off, 1x, 2x and 4x (default 2x, remembered). Software WebGL renders terrain very slowly, a real GPU is expected to be fine, but this has not been seen on one yet.

- **Roof shapes** (`static/roofs.js`, `/api/roofs`): OSM `roof:shape` ways become gabled, hipped, pyramidal, skillion and dome roofs on top of the extruded building. Gabled, hipped and skillion need a roughly rectangular footprint, other footprints keep the flat cap. The server reads `roofs.json` next to the graph manifest (written by `build-graph.sh`, published like `signals.json`); without it, it fetches cells from Overpass in the background and the client retries until they are ready. Buildings without a `height` or `building:levels` tag get a roof at a default height, so some will sit low.
- **Building facades and windows** (`static/facades.js`): procedural facades generated from building footprints with outward unit normals, wall coordinates, sills, cornices and a dedicated WebGL facade shader. Windows randomly light up as the sun sets (individual turn-on times per room across dusk and evening), glow with warm interior light, and shut down towards midnight until going almost fully dark after midnight (only ~2-3% night owls stay lit). At sunrise, window lights switch off for the day.

## If the app looks old

The page and every script URL carry a content hash of the build (`?v=...`, shown under About, "This device", and on `/healthz`). HTML and API answers are sent with `no-store` and CDN no-store headers, hashed assets are immutable. A device that shows a different build than `/healthz` is serving an old copy: reload once (the service worker takes the new page on the next load).

## MCP link

`transit_plan` and `route` return `app_link`, which opens the app on that exact trip (from, to, mode, time).

## API for other clients (`/api/v1/`)

`/api/v1/<name>` is the same as `/api/<name>`; the v1 prefix is the stable contract for a native app. JSON everywhere, `Authorization: Bearer <token>` or the cookie.

| Call | Purpose |
| --- | --- |
| `POST /api/v1/login` `{"secret", "device": "pixel-8"}` | named device: returns `{"token"}` valid 365 days. Without `device` it sets the web cookie |
| `GET /geocode?q=&lat=&lon=`, `/reverse?lat=&lon=` | places |
| `GET /plan?from=lat,lon&to=lat,lon&mode=transit\|walk\|bike\|car&transit=rail,bus,tram&at=ISO&by=depart\|arrive&n=3[&headroom_rail=10][&headroom_bus=5][&headroom_tram=3]` | itineraries; legs carry live times, delay, encoded polyline (precision 5), stops with coordinates, transfer headroom, `trip_id`, `stop_id` |
| `GET /vehicles?bbox=minLon,minLat,maxLon,maxLat[&lod=heat]` | live vehicles with line, mode, operator, destination, last position and feed time (up to 700 in a bbox of at most 1.5 by 1.0 degrees), or only positions for the heatmap |
| `GET /shape?trip=` | encoded trip shape, stops and signals with their distance along it |
| `GET /nearby?lat=&lon=&r=`, `/departures?stop=&n=`, `/trip?id=&date=`, `/info` | stops, departures, one trip, data age and attribution |
| `POST /watch` `{"legs":[{trip_id,line,from,to,scheduled_start}], "hours":6}`, `DELETE /watch?id=` | watch the transit legs of a trip (5 per device) |
| `GET /events?since=<id>` | events of this device: delay changes of watched trips (checked once a minute, threshold 2 minutes) |
| `POST /push` `{"kind":"fcm\|webpush","target":"..."}` | stores the delivery target of the device. Delivery is not implemented yet, `emit()` in `server.py` is the hook |

Watches and events live in `/var/lib/mcp-gateway/nav-state/nav.db` (sqlite). Events older than a day are dropped.

## Notifications and a native app (open decision)

- A PWA on Android can receive Web Push notifications (service worker plus VAPID keys, delivered through the browser vendor's push service). That fits "your train is 10 min late" and "leave now", driven by the watcher above, and needs no GPS.
- A PWA cannot keep a live, ongoing trip card on the lock screen the way Google Maps does, cannot track position in the background, and cannot use Android's Live Updates or progress notifications. Those need a native app (foreground location service, ongoing notification).
- Groundwork already in place: versioned API, device bearer tokens, trip watches, event feed, push target storage. A native client would poll `/events` or receive FCM once delivery is added.
- To discuss: native app (Kotlin) versus a thin wrapper, FCM project and key handling (sops), whether to publish outside the Play Store, battery cost of background tracking.

## Operations

- Logs: `sudo podman logs lab-nav` (almost empty by design). Restart: `sudo systemctl restart podman-lab-nav`.
- Deploy: edit, `git add`, `nixos-rebuild switch` for `rpi4`. The code is a store path, so no image rebuild.
- Local test: tunnel to the Pi's OTP and Nominatim container addresses, run `NAV_SECRET=... OTP_URL=... NOMINATIM_URL=... python3 pkgs/nav/server.py`, open `http://localhost:8080`. Unit tests: `python3 -m unittest discover -s pkgs/nav/tests`.
- The map needs WebGL. Without it the app still plans and shows times.
