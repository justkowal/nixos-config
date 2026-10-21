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
- Mode picker (transit, walk, bike, car), transit type filter (train, bus, tram), leave at or arrive by.
- Results as a journey ribbon, detail with every leg, intermediate stops, live status per leg, stop departures (auto refresh every 30 s).
- Live guidance (Start button): GPS follow with heading, next maneuver or boarding, stops remaining, get-off prompt, wake lock, optional voice, vibration.
  - Off route (more than 40 m walking, 60 m driving, 130 m on a vehicle, three fixes in a row) replans from the current position.
  - Every 45 s live times of the trips ahead are refreshed. If a vehicle will be missed, or the projected arrival is more than 5 minutes after the planned one, it searches for a way to arrive by the original arrival time and switches when the new plan arrives 3 or more minutes earlier (or the old one is no longer possible). While on a vehicle the new plan starts at the get-off stop.
  - `#sim=1` in the URL replays the route as fake GPS fixes for testing.
- Limits of a web app: geolocation pauses when the page is not in the foreground, so guidance needs the screen on (a wake lock is requested). Notifications while the app is closed need Web Push, see below.

## MCP link

`transit_plan` and `route` return `app_link`, which opens the app on that exact trip (from, to, mode, time).

## API for other clients (`/api/v1/`)

`/api/v1/<name>` is the same as `/api/<name>`; the v1 prefix is the stable contract for a native app. JSON everywhere, `Authorization: Bearer <token>` or the cookie.

| Call | Purpose |
| --- | --- |
| `POST /api/v1/login` `{"secret", "device": "pixel-8"}` | named device: returns `{"token"}` valid 365 days. Without `device` it sets the web cookie |
| `GET /geocode?q=&lat=&lon=`, `/reverse?lat=&lon=` | places |
| `GET /plan?from=lat,lon&to=lat,lon&mode=transit\|walk\|bike\|car&transit=rail,bus,tram&at=ISO&by=depart\|arrive&n=3` | itineraries; legs carry live times, delay, encoded polyline (precision 5), stops with coordinates, `trip_id`, `stop_id` |
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
