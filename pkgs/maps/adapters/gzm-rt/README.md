# gzm-rt

Realtime only adapter for the ZTM GZM (Metropolia GZM) network.

- Sources: the official GTFS-RT feeds on `gtfsrt.transportgzm.pl:5443` (CC BY, Zarzad Transportu Metropolitalnego) and, for the id tables only, `mkuran.pl/gtfs/gzm.zip` (one conditional request an hour).
- Why: the static graph uses the mkuran.pl feed, whose trip ids carry the publication number of the service day (`11607:1_6045354`). The official realtime ids are bare (`1_6045354`) and carry no date. This service rewrites the ids and sets `start_date`. Stop ids and stop sequences already agree between the two feeds.
- A trip that cannot be placed on today or yesterday (night lines) is dropped, never guessed. `/health` reports kept and dropped counts.
- Rules: honest User-Agent, one poll every 30 s per feed, exponential backoff after 5 errors, 6 h pause after a 403 or 429, no request headers beyond User-Agent and If-None-Match.
- Endpoints: `/gtfs-rt/trip-updates.pb`, `/gtfs-rt/vehicle-positions.pb`, `/health`.
- Tests: `docker build --target test .` (stdlib unittest plus protobuf).

Static data for the graph is not produced here: the desktop fetches the mkuran.pl zip itself and trims it with `pkgs/maps/trim_gtfs.py` (registry key `trim_days`).
