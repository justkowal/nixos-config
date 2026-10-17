# AccuBattery: what is built

All 21 roadmap items are implemented in `pkgs/accubattery` plus small changes in `labd`, `home/lab/battery.nix` and the roster script. This file records where each lives and the decisions that were not obvious. Anything still unverified on hardware is listed at the end.

## Data quality

| # | Item | Where |
|---|------|-------|
| 1 | Replay harness: CSV fixtures run through the engine, plus `accubattery replay FILE` | `tests/replay.rs`, `tests/fixtures/` |
| 2 | Rolling 48 h sample log, one file per battery | `src/ring.rs`, `~/.local/share/accubattery/ring-BAT0.csv` |
| 3 | Charge profile per adapter and 10 % band, used to date offline charges | `charge_profile` table, `engine::charge_seconds` |
| 4 | Gauge glitches (energy jump, capacity relearn) become notes, not sessions | `Event::Glitch`, `events` table, History "Gauge notes" |
| 5 | Startup repair of rows left open by crashes or the old Python logger | `Db::repair` |

To fix a wrong detection: copy the relevant stretch of `ring-BAT0.csv` into `tests/fixtures/`, add an expectation in `tests/replay.rs`, change the engine until it passes.

## Insight

| # | Item | Where |
|---|------|-------|
| 6 | Time to empty (decayed draw blended with hour-of-week habit) and time to target (learned profile). Computed by the daemon, shown as an estimate | `src/estimate.rs`, `hourly_draw` table |
| 7 | Per-app drain from CPU and GPU engine time, sampled while discharging | `src/apps.rs`, `top_apps_json` |
| 8 | Standby drain per night in mW, with the wakeup sources that fired during the suspend | `src/wake.rs`, `wake_json`, Health "Standby drain" |
| 9 | Habit score and one sentence of advice | `estimate::habit`, `daily` table |
| 10 | Health trend with dashed projection to 80 %, shown after 30 days and 8 points | `estimate::project_health`, `graph.rs` |

`hourly_draw` replaces the old `hourly_baseline`, which mixed charging power into the average. The old table is left untouched and unused.

## Lab integration

| # | Item | Where |
|---|------|-------|
| 11 | Events `battery.target`, `battery.low`, `battery.offline_charge`, `battery.trip` and their island cards. `swayosd-client` is only the fallback when `lab-publish` is missing | `src/notify.rs`, `pkgs/labd/src/island.rs`, `glyphs.rs` |
| 12 | Palette entries in group Battery | `home/lab/battery.nix` |
| 13 | Keymap `SUPER ALT B` (window) and `SUPER ALT SHIFT B` (trip), scenes `travel` and `desk` | `home/lab/battery.nix` |
| 14 | Chart text size and line width come from `~/.config/lab/tokens.json` | `src/bin/accubattery-gui/tokens.rs` |
| 15 | No CSS provider added: the tokens carry no colours, Matugen themes GTK itself, so libadwaita colours are already right | none |

## Control

| # | Item | Where |
|---|------|-------|
| 16 | One-shot full charge: `accubattery trip [HOURS\|--cancel]`, ends on timeout or after 60 s unplugged, re-applied if the calendar timer resets it | `src/control.rs` |
| 17 | No new polkit helper. TLP owns the thresholds and `modules/battery-schedule.nix` already lets the user start `battery-charge@travel` and `battery-charge@default` without a prompt, so the app uses those units. Sysfs writes are only a fallback. The display saving files are already world writable | `control::set_mode` |
| 18 | Weekly schedule: `accubattery schedule DAY HH:MM [LEAD_HOURS]` or the Settings page. Starts a trip inside the lead window once per week, so the calendar check keeps covering travel days | `control::decide`, `window_left` |
| 19 | One engine per battery, rows carry a `battery` column, the window shows the first battery and tags the rest | `Battery::find_all`, `Runner` in `src/main.rs` |

## Fleet

| # | Item | Where |
|---|------|-------|
| 20 | Summary line served on the tailscale address only, port 47651. The roster script adds `battery {pct,status,ac}` to laptop entries and the island shows it as a percentage next to the device name | `src/fleet.rs`, `home/scripts/lab-roster.py`, `island.rs` |
| 21 | Export history: `accubattery export csv\|json [PATH]` and an Export button on the History page | `src/export.rs` |

## Not verified on hardware

* Suspend and power-off detection ran on synthetic fixtures only. Leave the daemon running through a few real nights, then check History for "Charged asleep" and "Charged while off" rows. If one is wrong, add its samples as a fixture.
* Wakeup source names depend on what the kernel exposes under `/sys/class/wakeup`.
* The roster battery chip needs the daemon running on the laptop and the tailnet reachable. The listener binds only the tailscale address.
* GPU attribution reads `/proc/PID/fdinfo` and only sees processes of the same user.
* The weekly schedule and the trip timer have unit tests for their decisions, but they have not yet driven real TLP threshold changes.

## Still open

* Should the daemon keep the sleep inhibitor while charging? It blocks lid-close sleep on AC. Offline detection now covers the gap, so it could become opt-in.
