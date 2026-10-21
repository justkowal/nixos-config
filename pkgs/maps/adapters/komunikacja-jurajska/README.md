# komunikacja-jurajska adapter: BLOCKED at R1

Status: not built. The source's robots.txt forbids all automated access, so per the project rules this source is stopped and needs an owner decision.

## R1 findings (checked 2026-10-21, 5 requests total, spaced >= 4 s, honest User-Agent)

| URL | Result |
|---|---|
| https://kiedyprzyjedzie.pl/robots.txt | 404 (no rules on the main domain) |
| http://komunikacjajurajska.kiedyprzyjedzie.pl/robots.txt | 200: `User-agent: *` / `Disallow: /` |
| https://www.komunikacjajurajska.pl/robots.txt | 404 (operator site, no rules) |

- The Komunikacja Jurajska deployment lives on its own subdomain, `komunikacjajurajska.kiedyprzyjedzie.pl` (listed on https://kiedyprzyjedzie.pl/deployments). That subdomain disallows every path for every user agent, so its data endpoints are covered.
- No terms of use for automated access were found on the main site: only a privacy policy PDF and a cookie notice are linked. The robots.txt is the only machine-readable statement, and it says no.
- The operator site (www.komunikacjajurajska.pl) links to BIP and to the kiedyprzyjedzie subdomain. No GTFS or other machine-readable timetable was found on its landing page (it returned a "Brak strony" page at /). Timetables are PDFs, as expected. Not searched further to avoid crawling.
- The vendor (kiedyPrzyjedzie.pl, info@kiedyprzyjedzie.pl) sells a service to carriers. Its public pages describe no open API.

No fixtures, adapter code or Docker image were produced, and no request was made to any data endpoint on the blocked subdomain. The saved robots.txt is in `reports/kj.kiedyprzyjedzie.pl-robots.txt`.

## Options for the owner

1. Ask Komunikacja Jurajska or kiedyPrzyjedzie.pl (info@kiedyprzyjedzie.pl) for written permission, or for a GTFS/GTFS-RT feed for personal use. Then build the adapter.
2. Ask the operator for GTFS directly: as a public body (BIP) it may share timetable data on request (dostep do informacji publicznej).
3. Build a static-only feed by hand-transcribing the operator PDFs (no realtime, laborious, not recommended).
4. Drop the source.
