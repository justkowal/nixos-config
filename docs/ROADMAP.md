# Fleet Roadmap

Plan for the next batch of features across `desktop`, `laptop`, `rpi4` and `vm`. Nothing here is implemented yet unless marked otherwise.

Effort is rough working days for one person: **S** = under 1 day, **M** = 1 to 3 days, **L** = 3+ days. Hardware prices are approximate gross PLN (23% VAT included) at Botland / TME / Kamami; check before ordering.

## What already exists (found while planning)

These change the scope of some items below:

- **Sunshine** is already enabled on the desktop (`hosts/desktop/configuration.nix`, `services.sunshine`, autoStart, capSysAdmin). Item 1 only adds the wake and headless parts.
- **TPM2 unlock** is already configured on the laptop (`crypttab` with `tpm2-device=auto`). Dropped from the earlier idea list.
- **Laptop root is btrfs on LUKS**, desktop root is **bcachefs**. Snapshot features (7, 8) need both backends.
- **Wake hooks** exist on the rpi4 webhook receiver: `wake-worker`, `wake-desktop`, `wake-wol`, `reset-worker` (`hosts/rpi4/configuration.nix`). Several items reuse them.
- **CI** (this branch): `.woodpecker.yaml` builds all hosts on the desktop worker and pushes closures to the rpi4 store served by harmonia. Still needs the `cache_push_key` secret, a deploy of desktop and rpi4, and a first green run.

## Phase overview

| Phase | Theme | Items | Why this order |
| :--- | :--- | :--- | :--- |
| 0 | Finish CI | CI go-live | Everything in phase 2 builds on it |
| 1 | Safety net | Backups (prereq), 10, 2, 9 | Data protection and visibility before risky changes |
| 2 | Delivery | Auto-deploy (prereq), 6, 12, 11 | Hands-off updates, only after backups and metrics exist |
| 3 | Workstation | 7, 8, 17, 16, 18 | Ephemeral root needs backups; the rest are independent |
| 4 | Energy and hardware | 14, 13, 15, 3, 1 | Needs metrics from phase 1; hardware can be ordered early |

Items inside a phase are mostly independent and can be done in any order unless a dependency is listed.

---

## Phase 0: CI go-live

**Steps**
1. Add the Woodpecker repo secret `cache_push_key` in ci.lab (the private key from this session's scratchpad), then delete the local copy.
2. Deploy rpi4 (new `nix-push` user) and desktop (new local-backend agent in the worker specialisation).
3. Enable `justkowal/nixos-configs` in ci.lab, push to the Forgejo remote, watch the first run.
4. Confirm the local agent picks the job up (`backend: local` label) and the docker agent does not.

**Done when:** a push to `main` produces a green pipeline and `nix path-info --store https://cache.lab <desktop toplevel>` succeeds.

**Watch:** rpi4 disk usage. Every pushed desktop closure lands on the Pi; make sure `nh clean` runs there and consider keeping only the last N pushed systems as GC roots.

---

## Phase 1: Safety net

### Prereq: workstation and off-site backups (from the first idea list)

- restic timers for `~` on desktop and laptop to a restic REST server on the rpi4 (append-only mode so a compromised client cannot delete history).
- Nightly encrypted restic copy of the rpi4 state (homelab-state-backup output, Forgejo dumps, Paperless, Vaultwarden) to an off-site EU target such as a Hetzner Storage Box.
- Passwords via sops-nix. Failures go to ntfy.
- Effort: **M**.

### 10. Lightweight observability

**Goal:** metrics and alerts for the whole fleet without Grafana or a heavy Prometheus on a 4 GB Pi.

**Design**
- rpi4: `services.victoriametrics` (single node, 90 day retention) plus `vmalert`.
- Every host: node exporter and `vmagent` with remote write to the Pi. vmagent buffers to disk while offline, so a sleeping desktop or a laptop on the road uploads its gap on reconnect.
- Alerts: vmalert rules (disk > 85%, failed systemd units, backup older than 26 h, SMART errors, CI agent offline) to a small webhook on the Pi that posts to ntfy.
- Graphs: VictoriaMetrics' built-in vmui behind Caddy at `metrics.lab`. Add a Glance link.

**Files:** new `modules/monitoring.nix` (client side, imported by all hosts), `hosts/rpi4/apps.nix` (server), `modules/lab-hosts.nix` (`metrics.lab`).

**Done when:** each host shows up in vmui, and stopping a unit on purpose produces an ntfy alert.

**Effort:** **M**. **Risk:** low. Check Pi RAM after a week (expect ~150 to 250 MB).

### 2. Automated disaster-recovery drill

**Goal:** prove monthly that the rpi4 can be rebuilt from backups.

**Design**
- A Woodpecker cron pipeline (monthly) on the desktop's local agent.
- Build an **x86_64 test VM** that imports the rpi4 service modules (`hosts/rpi4/apps.nix` and friends, now split out, which makes this possible) without the Pi hardware and SD image modules. Emulating aarch64 would be far too slow.
- Restore the latest backup into the VM's state directories (restic restore from the REST server).
- Secrets: the VM gets its own age key and a small test sops file; real secrets never enter the VM or the Nix store.
- Probe each service: Kanidm login API, Forgejo repo listing, Vaultwarden `/alive`, Paperless document count, Woodpecker API. Compare counts against the live Pi.
- Result to ntfy with a short report.

**Done when:** a drill passes, and deliberately corrupting a backup makes it fail.

**Depends on:** backups prereq. **Effort:** **L**. **Risk:** medium; some services may assume Pi-specific paths, which is itself useful to discover.

### 9. rpi4 resilience

**Goal:** a dead Pi or SD card is an hour of downtime, not a weekend.

Real failover is limited because the desktop sleeps most of the time, so this focuses on fast recovery and graceful degradation.

**Design**
- **Storage:** move the Pi root from SD to a USB 3 SSD (SD cards are the most common Pi failure). Keep the SD only as a boot fallback.
- **Ready-to-flash image:** CI also builds `config.system.build.sdImage` for rpi4 and keeps the last good one on the desktop.
- **Graceful degradation already partly there:** nix `fallback = true` and `connect-timeout = 3`, and the boot router handles an unreachable Pi. Add: fallback DNS on clients when Blocky is down (secondary resolver in NetworkManager), and check that `kanidm-unixd` offline credential caching works on desktop and laptop.
- **Runbook:** `docs/RPI4_RECOVERY.md` covering flash, restore age host key, restic restore, verify. The drill (item 2) keeps it honest.

**Effort:** **M** (plus a USB SSD, ~120 to 200 PLN for a 256 GB SATA SSD + USB 3 adapter; avoid adapters with poor UASP support on Pi 4).

---

## Phase 2: Delivery

### Prereq: auto-deploy from green builds (from the first idea list)

Today `modules/auto-update.nix` runs `nix flake update` on every host daily, builds locally, and asks before switching. Change it to:

- CI writes the green toplevel path of each host to a small manifest served by Caddy (`https://cache.lab/fleet/<host>`), as part of the push step.
- Hosts fetch that path, `nix-store --realise` it from cache.lab (no local build), and switch.
- `flake.lock` updates move to CI (a weekly cron that updates, builds, and opens a Forgejo PR with the `nvd diff`).

**Effort:** **M**.

### 6. Staged rollouts with automatic rollback

**Goal:** updates roll out without supervision and undo themselves if something breaks.

**Design**
- Order: `vm` (if kept running as a canary), then `laptop`, then `desktop`. Each stage waits for the previous stage to report healthy (a status file next to the manifest).
- After switching, a `fleet-health` oneshot runs on the host:
  - no failed system units
  - rpi4 reachable over Tailscale
  - display manager / Hyprland session start (on graphical hosts)
  - host-specific probes (desktop: Docker, Woodpecker agent)
- On failure: switch to the previous generation, mark the manifest entry bad, ntfy alert with the failing check.
- Never switch the laptop while on battery below 30% or while a presentation or meeting is in progress (caffeine active as a proxy).

**Depends on:** auto-deploy prereq, item 10 (alerts). **Effort:** **L**. **Risk:** medium; test the rollback path on the VM first.

### 12. Tailscale access rules in the repo

**Goal:** network access is reviewed and versioned like the rest of the config.

**Design**
- `tailscale/policy.hujson` in this repo with tags: `tag:orchestrator` (rpi4), `tag:worker` (desktop), `tag:roaming` (laptop, phone).
- Policy `tests` block asserting the important paths (laptop to `*.lab` HTTPS, worker to rpi4:9000, nothing inbound to the laptop except SSH from the desktop).
- Woodpecker: on PR, validate via the Tailscale API; on `main`, apply. API key as a Woodpecker secret.

**Effort:** **M**. **Risk:** lockout. Keep admin console access, apply first with a permissive rule plus tests, then tighten.

### 11. Throwaway preview environments

**Goal:** every branch of a web project gets a live URL.

**Design**
- Woodpecker on `pull_request` builds a NixOS container config from the project flake and starts it on the desktop as a `nixos-container` (systemd-nspawn).
- Container creation needs root, so the CI agent does not get it directly: a root-owned systemd service watches a spool directory for small, validated JSON requests (`create`/`destroy`, repo, branch, flake ref).
- Caddy on the rpi4 routes `*.dev.lab` to the desktop, Blocky resolves the wildcard, and a wake-on-request rule wakes the desktop when a preview is opened.
- Destroyed on merge or after 7 days.
- Only for your own repos (same `repo=` agent label trick as the nix agent).

**Effort:** **L**. **Risk:** medium (privileged spool service is the part to review carefully).

---

## Phase 3: Workstation

### 7. Root wiped on every boot

**Goal:** no configuration drift; anything that should survive is declared.

**Design**
- Add the `nix-community/impermanence` flake input (standard, small).
- Laptop (btrfs): initrd step restores `/` from a blank snapshot each boot; `/persist` and `/home` stay.
- Desktop (bcachefs): same with a bcachefs subvolume snapshot.
- Declared persistence: `/etc/ssh` host keys (sops depends on them), NetworkManager connections, `/var/lib` for stateful services (docker scratch is already on its own disk, tailscale, bluetooth, fprintd on the laptop, sops age keys), `/var/log` optional.
- Rollout: VM first, then laptop, then desktop. Before each, run a "what would be lost" diff (list files on `/` not in the Nix store and not persisted).

**Depends on:** backups prereq. **Effort:** **L**. **Risk:** high if a persist path is missed. Losing `/etc/ssh` breaks sops; persist it first and test decryption before the first wipe.

### 8. Snapshot time machine

**Goal:** browse and restore any file from the last days without touching backups.

**Design**
- Laptop: `btrbk` hourly snapshots of `/home` (keep 24 hourly, 7 daily).
- Desktop: a timer running `bcachefs subvolume snapshot` with the same retention, pruned by a small script.
- GUI: a GTK4/libadwaita app in `home/scripts/guis/` in the same style as the existing GUIs (own `app_id`, worker thread for filesystem scans): pick a folder, scrub through time, diff and restore a file. Launch from the control center and from Dolphin's context menu.

**Depends on:** item 7 if done (snapshots then live under `/persist`). **Effort:** **M** to **L** (the GUI is most of it).

### 17. Project rooms

**Goal:** reopen a project's whole workspace layout in one action.

**Design**
- `room save <name>`: `hyprctl clients -j` filtered to the current workspace(s), stored as JSON in `~/.local/state/rooms/<name>.json` with app class, workspace, size and, for terminals, the working directory (read from the process cwd).
- `room open <name>`: relaunch each window with Hyprland exec rules (`[workspace N silent]`), terminals with their working directory and dev shell, browser with a per-project profile.
- fuzzel picker listing rooms, plus one room per git repo under `~/` detected automatically.

**Effort:** **M**. **Risk:** low. Apps that cannot be relaunched with state are simply reopened fresh.

### 16. Automatic handoff when the laptop arrives

**Goal:** laptop and desktop act as one workspace when both are home, without manual setup.

**Design**
- Laptop: a NetworkManager dispatcher (home SSID or the desktop reachable over LAN, not just Tailscale) starts a user target `home-lan.target`; leaving stops it.
- Bound to the target: lan-mouse with the edge configured for your desk layout, KDE Connect clipboard and notification sync, optional PipeWire network sink so laptop audio can play through the desktop speakers.
- Desktop side reacts to the laptop appearing via the same lan-mouse peer discovery already in `peer_discovery.py`.
- Waybar indicator on both sides; one click to suspend the handoff.

**Effort:** **M**. **Risk:** low.

### 18. Focus mode across the fleet

**Goal:** one toggle for deep work, honoured by every device.

**Design**
- State lives on the rpi4 (single source of truth), switched via two new webhook hooks `focus-on` / `focus-off`, broadcast on an ntfy topic.
- Effects:
  - ntfy listeners on desktop and laptop drop non-urgent messages while focus is on
  - Blocky: a `distractions` denylist group, normally disabled, enabled via Blocky's blocking API for the duration
  - `pomodoro.sh` and `caffeine.sh` start
  - rpi4 OLED shows the remaining time
  - OpenRGB profile on the desktop
- Ends automatically when the pomodoro finishes; Waybar module toggles it.

**Effort:** **M**. **Risk:** low.

---

## Phase 4: Energy and hardware

Order the hardware at the start of phase 1 so it is there when needed.

### 14. Energy cost per job in PLN

**Goal:** know what the desktop actually costs per CI run, render or gaming session.

**Design**
- Shelly Plug S Gen3 on the desktop's power strip (~80 to 100 PLN), local HTTP RPC only, no cloud. Note the 2500 W limit; fine for this machine.
- A tiny exporter on the rpi4 scrapes `Switch.GetStatus` (power and energy counters) into VictoriaMetrics.
- Cost = energy x tariff price for the zone it was used in (energy + distribution, gross), tariff kept as data in the repo.
- CI pipelines record start and end; a summary step queries the energy used in that window and prints the PLN cost. A Glance widget shows today / month.

**Depends on:** item 10. **Effort:** **M**.

### 13. Scheduler for cheap-tariff hours

**Goal:** heavy batch work runs when electricity is cheapest.

**Design**
- Tariff windows as data (G12 off-peak zones differ by operator; typical: 22:00 to 06:00 and 13:00 to 15:00).
- A simple job spool on the rpi4: each job has a command target (desktop worker) and a deadline. At the start of a cheap window, or when a deadline would otherwise be missed, the Pi wakes the worker (`wake-worker` hook) and the jobs run; the existing autoshutdown returns the desktop to sleep.
- First users: weekly flake.lock update, Flamenco renders submitted with "render tonight", DR drill (item 2), large rebuilds.

**Depends on:** item 14 for proof it saves money (optional). **Effort:** **M**.

### 15. Calendar-aware battery charging

**Goal:** long battery life for a laptop that is mostly plugged in, full charge when you actually travel.

**Design**
- TLP already sets `STOP_CHARGE_THRESH_BAT0 = 90` (`hosts/laptop/configuration.nix`, `modules/power-saving.nix`). Lower the default to 60 to 80% there and do the temporary overrides with `tlp setcharge`, so TLP stays the only thing owning the thresholds.
- A user service checks the calendar (evolution-data-server is already enabled; query via the EDS GObject bindings) each evening: if tomorrow has an event marked travel or located away from home, raise the end threshold to 100% overnight.
- Manual override in the existing AccuBattery GUI.
- Wear history: log `energy_full` / `energy_full_design` daily into VictoriaMetrics; the GUI shows the curve.

**Effort:** **M**. **Risk:** low.

### 3. Desk environment sensors on the rpi4

**Goal:** air quality and climate at the desk, with a nudge to ventilate.

**Hardware (approx.)**
- Sensirion SCD41 breakout (CO2, true NDIR), ~200 PLN, I2C address 0x62
- BME280 breakout (temperature, humidity, pressure), ~40 PLN, I2C 0x76/0x77
- Qwiic/STEMMA QT cables, ~15 PLN
- M2.5 standoffs and DIN 912 M2.5 screws for mounting on the Argon case

Both share the I2C bus with the OLED (typically 0x3C), so no address conflicts.

**Design**
- Extend `hosts/rpi4/scripts/oled-dashboard.py` to read both sensors (or a separate small service writing to a state file the dashboard reads).
- Export to VictoriaMetrics; Waybar and Glance read the latest values.
- ntfy alert when CO2 passes 1200 ppm, cleared below 800 ppm.

**Depends on:** item 10 for history (optional). **Effort:** **S** to **M**.

### 1. Streaming that wakes the desktop

**Goal:** the full desktop and Steam library from the laptop or phone, with the desktop asleep otherwise.

Sunshine is already enabled; this adds the missing pieces.

**Design**
- `play.lab`: opening it (or a Moonlight pre-launch hook) calls the rpi4 `wake-desktop` hook. Moonlight's own Wake-on-LAN does not cross Tailscale, so the Pi relays it.
- Headless display: in worker mode greetd is disabled and there is no monitor. Either an HDMI dummy plug (~30 PLN) or an EDID override (`drm.edid_firmware`) gives Sunshine a KMS output to capture; then start a gamescope or Hyprland session on it when a stream starts.
- Idle: when no client has been connected for N minutes and no CI or render job is running, let the existing autoshutdown logic suspend or power off.
- Waybar / fleet menu entry on the laptop: "Stream desktop".

**Effort:** **M**. **Risk:** low to medium (headless capture is the fiddly part; the dummy plug is the reliable fallback).

---

## Cross-cutting

**New secrets (sops-nix)**
- restic repository passwords (desktop, laptop, rpi4 off-site)
- Tailscale API key (item 12, as a Woodpecker secret)
- off-site storage credentials
- DR drill test age key (item 2)

**New flake inputs**
- `impermanence` (item 7). Nothing else needs a new input.

**Shopping list (approx. gross)**

| Item | For | Price |
| :--- | :--- | ---: |
| USB 3 SSD + UASP adapter | 9 | 120 to 200 PLN |
| Shelly Plug S Gen3 | 14 | 80 to 100 PLN |
| SCD41 breakout | 3 | ~200 PLN |
| BME280 breakout | 3 | ~40 PLN |
| Qwiic cables, standoffs, DIN 912 M2.5 | 3 | ~30 PLN |
| HDMI dummy plug (optional) | 1 | ~30 PLN |
| **Total** | | **~500 to 600 PLN** |

**Not in this plan (on purpose)**
- Local AI features (dropped).
- Photo handling; the Immich restoration is a separate task.
- Hardware security keys.
