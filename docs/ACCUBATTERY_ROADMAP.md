# AccuBattery roadmap

State today: `pkgs/accubattery` has the session engine and daemon (`accubattery`) and the GTK window (`accubattery-gui`). Sessions are detected from the gauge, including charges and drains that happened asleep or powered off. This file ranks what to build next. Every item names the file it touches, so each one fits a single change.

## Ranking rules

1. Fixes that make the recorded data wrong come before features that read it.
2. Anything the island or the palette must show goes through the bus (`docs/LAB_GUIDELINES.md`), never `notify-send` or its own OSD.
3. Prefer measuring over modelling. A guess shown as a number needs a label saying it is a guess.

## Tier 1: data quality

| # | Item | Why | Where |
|---|------|-----|-------|
| 1 | Validate the engine on real suspend and power-off cycles with a replay harness | the unit tests use synthetic samples; real firmware reports odd statuses | `src/engine.rs`, new `tests/replay.rs` fed from recorded sample CSV |
| 2 | Record raw samples to a rolling ring file (last 48 h, 1 sample per 10 s) | lets a bad detection be replayed and fixed without waiting a day | `src/main.rs`, new `src/ring.rs` |
| 3 | Learn the charger profile per adapter (W seen at 20, 50, 80 %) and use it to date offline charges | `ref_charge_w` is one number, charge speed tapers | `src/engine.rs`, `src/db.rs` table `charge_profile` |
| 4 | Detect gauge recalibration jumps (energy_full changes, percent jumps without flow) and mark them instead of logging fake sessions | firmware relearns capacity on a full cycle | `src/engine.rs` |
| 5 | Import the old Python history rows as `kind='live'` and keep them (already compatible), add a one-time `integrity` pass that closes rows left open by the old daemon | old rows have duration 0 and hide from the list | `src/db.rs` |

## Tier 2: smarter insight

| # | Item | Why | Where |
|---|------|-----|-------|
| 6 | Real estimates: time to empty from a decayed average of recent draw plus the hour-of-week baseline, time to target from the learned charge profile | the GUI ETA is linear with a fixed taper factor | new `src/estimate.rs`, used by daemon and GUI |
| 7 | Per-app drain, sampled in the daemon from `/proc` CPU time plus GPU busy from sysfs, saved into `top_apps_json` | the Python window did this and the Rust window does not yet | new `src/apps.rs` |
| 8 | Standby drain report: mW while asleep per night, flag nights above a threshold and show which wake source (read `/sys/power/wakeup_count`, `/sys/kernel/debug/wakeup_sources` when readable) | sleep drain is the biggest silent loss on laptops | `src/engine.rs`, `src/db.rs`, GUI History |
| 9 | Charge habit score: share of charges ending between 20 and 80 %, hours spent above 90 %, with one plain suggestion | gives the wear model something actionable | GUI Health page |
| 10 | Health trend with a fitted line and a projected date for 80 % health, hidden until 30 days of data exist | the current graph only shows past points | GUI `graph.rs` (add a dashed series) |

## Tier 3: Lab integration (hard rules 2 and 3)

| # | Item | Where |
|---|------|-------|
| 11 | Publish `battery.target` (charge alarm), `battery.low`, `battery.offline_charge` events to the bus; add the matching cards in `card_for` | `pkgs/labd/src/island.rs`, replace `swayosd-client` in `src/main.rs` |
| 12 | Palette entries: Battery sessions, Charge to 80 %, Charge to 100 % once, Display power saving on or off | `home/lab/palette.nix` |
| 13 | Keymap entry and scene hook: scene "Travel" sets conservation off, display saving maximum, and arms the low battery event | `home/lab/`, `docs/DESKTOP_ENVIRONMENT.md` |
| 14 | Read design tokens (`~/.config/lab/tokens.json`) for graph line widths and text size so the window follows the Lab skin | `src/bin/accubattery-gui/graph.rs` |
| 15 | Matugen accent already follows libadwaita; add a CSS provider only if the Lab tokens define more than accent | GUI `main.rs` |

## Tier 4: control

| # | Item | Why | Where |
|---|------|-----|-------|
| 16 | One-shot "charge to 100 % for a trip" that restores the 80 % limit when unplugged or after N hours | removes the habit of forgetting to switch back | daemon owns the timer, writes thresholds through a small polkit helper |
| 17 | Polkit action for charge thresholds and ABM so the window stops using `pkexec sh -c` | the shell string is fragile and prompts every time | `modules/`, one rule file |
| 18 | Schedule: full charge before a calendar-less fixed weekday time (for example Monday 06:30) | covers the predictable case without calendar integration | daemon, settings table |
| 19 | Multi-battery support (BAT0 and BAT1 on ThinkPads with external batteries): one engine per battery | `Battery::find` takes the first | `src/battery.rs`, `src/main.rs` |

## Tier 5: fleet

| # | Item | Where |
|---|------|-------|
| 20 | Publish a one-line battery summary to the device roster so the desktop and the Pi hub can show laptop state | `home/lab/roster.nix`, `accubattery status` already prints JSON |
| 21 | Export history as CSV and JSON from the window | GUI History page |

## Suggested order

Items 1 and 2 first, since everything else trusts the engine. Then 11 and 12 (small, visible), 6 and 7 (restore parity with the old window and beat it), then 8 and 16.

## Open questions for the owner

* Should the daemon keep the sleep inhibitor while charging at all? It guarantees clean logs but blocks lid-close sleep on AC. The offline detection now covers the gap, so the inhibitor could become opt-in.
* Is a one-off 100 % charge allowed to override the conservation limit automatically, or should it always ask?
