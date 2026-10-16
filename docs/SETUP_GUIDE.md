# Roadmap Setup Guide

Everything from `docs/ROADMAP.md` is committed on `perf-benchmarks`. This guide walks through bringing it to life, in the order that avoids surprises. Each step says what it needs, what to change, and how to check it worked.

Work top to bottom. Steps 1 and 2 are required; after that every section is independent unless it says otherwise, so skip anything you don't want yet.

## Conventions used below

**Rebuild a host** (run from the repo on the desktop or laptop):

```bash
sudo nixos-rebuild switch --flake .#desktop
```

```bash
sudo nixos-rebuild switch --flake .#laptop
```

```bash
nixos-rebuild switch --flake .#rpi4 --target-host justkowal@nixos-rpi4.lab --sudo
```

The rpi4 build runs on the machine you type it on (the desktop builds aarch64 through binfmt).

**Edit secrets.** All hosts share one sops file. Desktop and laptop decrypt it with `~/.config/sops/age/keys.txt`, the rpi4 with its SSH host key.

```bash
sops hosts/rpi4/secrets/secrets.yaml
```

Make sure `~/.config/sops/age/keys.txt` exists on the laptop too (same admin key as the desktop), otherwise the laptop can't read its new secrets.

**Generate a random secret:**

```bash
openssl rand -base64 32
```

**Turning a feature on** means adding a line like `lab.backup.client.enable = true;` to the host file named in that step, next to the existing `# roadmap features` block, then rebuilding.

---

## 1. Ship the base (required)

### 1.1 Push

```bash
git push origin perf-benchmarks
```

```bash
git push backup perf-benchmarks
```

Merge into `main` on Forgejo (`git.lab/justkowal/nixos-configs`) when you're happy. CI only acts on `main`.

### 1.2 Deploy in this order

1. **rpi4 first.** It gains the `nix-push` user, VictoriaMetrics, vmalert, the focus hooks, and the Woodpecker backup path fix.
2. **Desktop.** It gains the local-backend CI agent (worker mode only), monitoring client, energy cost script, image storage, and the watchdog fix.
3. **Laptop.** It gains the monitoring client and the battery schedule.

**Check:**
- `https://metrics.lab` opens vmui. Within a minute, `up` shows rpi4, desktop and laptop.
- `systemctl status victoriametrics vmalert-lab alert-ntfy` on the rpi4 shows all three active.

### 1.3 Turn on CI

1. **Add the push key.** In ci.lab, open `justkowal/nixos-configs`, go to Settings, then Secrets, and add `cache_push_key` with the contents of the private key from the planning session:
   `/tmp/claude-1000/-home-justkowal-nixos-config/a1a1dc9a-07af-4822-b5a8-4c9df0d337a5/scratchpad/cache_push_key`
   Then delete that file. If the file is gone (scratchpads get cleaned), generate a new pair, put the new public key into `hosts/rpi4/apps.nix` (the `nix-push` authorized key), and redeploy the rpi4:
   ```bash
   ssh-keygen -t ed25519 -N '' -C woodpecker-cache-push -f ./cache_push_key
   ```
2. **Enable the repo** in ci.lab if it isn't already.
3. **Wake the desktop for CI.** Woodpecker can only run when the desktop is in worker mode. In Forgejo, add a repo webhook to `http://nixos-rpi4.lab:9100/hooks/wake-worker` on push.
4. **Push something to `main`.** The `build` workflow runs check, build and push-cache.

**Check:**

```bash
nix path-info --store https://cache.lab $(nix eval --raw .#nixosConfigurations.laptop.config.system.build.toplevel)
```

It prints the path instead of an error.

**Expected red builds until you do the matching steps below:**
- `promote` fails until `forgejo_deploy_token` exists (step 4).
- `tailscale-acl` fails until `tailscale_api_key` exists (step 5).

Both are harmless.

---

## 2. What already works after step 1

- **Monitoring:** vmui at `https://metrics.lab`. Alerts go to ntfy topic `alerts` (disk over 85%, failed units, stale backups once step 3 is done, rpi4 down).
- **Focus mode:** `focus on 50`, `focus off`, `focus status`, or `Super+Alt+P`.
  - On the rpi4 it enables the `distractions` Blocky group and publishes to ntfy topic `focus`.
  - On your machine it starts the pomodoro and caffeine.
  - The OLED shows the remaining time.
- **Project rooms:**
  - `room save <name>` saves the current workspace.
  - `room open <name>` restores it.
  - `room pick` (or `Super+Alt+R`) opens a rofi list of rooms plus git repos under `~`.
- **Battery schedule (laptop):** at 21:00 it checks tomorrow's calendar. If an event mentions "travel", it charges to 100% tonight. A daily wear log lands in metrics as `battery_health_ratio`.
- **rpi4 images:** every push touching `hosts/rpi4/**` or `flake.lock` leaves a flashable image in `/var/lib/rpi4-images/` on the desktop (last 3 kept).
- **Energy cost script:** `ci-energy-cost <start> <end>` is installed on the desktop. It only returns numbers after step 10.

---

## 3. Backups and the DR drill

**Needs:** a Hetzner Storage Box (or any restic-compatible off-site target) with SSH enabled on port 23.

### 3.1 Secrets

```bash
sops hosts/rpi4/secrets/secrets.yaml
```

Add these keys:

| Key | Value |
| :--- | :--- |
| `restic_nixos-desktop_password` | random; the desktop's repo password. Keep a copy offline, without it the backup is unreadable |
| `restic_thinkpad-t14s-gen1-amd_password` | random; laptop repo password, same advice |
| `restic_nixos-desktop_rest_password` | random; REST login for the desktop (username is the hostname) |
| `restic_thinkpad-t14s-gen1-amd_rest_password` | random; REST login for the laptop |
| `restic_server_htpasswd` | two bcrypt lines, one per host, made from the REST passwords (command below) |
| `restic_offsite_password` | random; off-site repo password, keep a copy offline |
| `restic_offsite_ssh_key` | private key for the Storage Box (command below) |

Make the htpasswd lines (`-nbB` prints `user:hash`):

```bash
nix shell nixpkgs#apacheHttpd -c htpasswd -nbB nixos-desktop 'REST_PASSWORD_HERE'
```

```bash
nix shell nixpkgs#apacheHttpd -c htpasswd -nbB thinkpad-t14s-gen1-amd 'REST_PASSWORD_HERE'
```

Make the Storage Box key, and upload `restic_offsite.pub` to the box's authorized keys:

```bash
ssh-keygen -t ed25519 -N '' -C restic-offsite -f ./restic_offsite
```

### 3.2 Turn it on

- **`hosts/rpi4/configuration.nix`:**
  ```nix
  lab.backup.server.enable = true;
  lab.backup.offsite.enable = true;
  lab.backup.offsite.repository = "sftp:uXXXXXX@uXXXXXX.your-storagebox.de:restic-rpi4";
  ```
- **`hosts/desktop/configuration.nix` and `hosts/laptop/configuration.nix`:**
  ```nix
  lab.backup.client.enable = true;
  ```

Deploy the rpi4 first, then the clients.

### 3.3 Initialise and test

On each client, run the first backup by hand. Restic creates the repo on the first run:

```bash
sudo systemctl start restic-backups-home
```

```bash
journalctl -u restic-backups-home -n 30
```

On the rpi4:

```bash
sudo systemctl start restic-backups-offsite
```

**Check:**
- `restic_last_success_timestamp_seconds` shows up in vmui for each client.
- A failure posts to ntfy topic `backups`.

**Note:** clients cannot delete snapshots (append-only). Pruning runs on the rpi4 on Sundays.

### 3.4 DR drill (monthly)

1. **Woodpecker secrets:**
   - `dr_restic_repository`: the off-site repo string.
   - `dr_restic_password`: same value as `restic_offsite_password`.
   - Optional, for comparing counts with the live Pi: `dr_forgejo_token`, `dr_paperless_token`.
2. **Cron:** in ci.lab, add a cron named `dr-drill`, monthly, on `main`.
3. **Run it once** manually from ci.lab. The report goes to ntfy topic `dr-drill`.

**Expect:** the first run may need fixes. The Forgejo dump layout and the Kanidm login probe were written from memory and haven't run yet.

---

## 4. Automatic deploys with rollback

**Needs:** step 1 working (green builds, cache populated).

### 4.1 Forgejo tokens

Create two tokens in Forgejo (user settings, Applications):
- `forgejo_deploy_token`: repo write. CI uses it to push `deploy/canary`.
- `forgejo_bot_token`: repo write and PR creation. Used by the weekly lock update.

Add both as Woodpecker secrets on the repo.

Optional: branch protection on `deploy/*` so only the deploy token can push.

If the repo is **private**, hosts can't fetch `deploy/*` anonymously. Either make it public on the forge, or add a read token via `nix.settings.netrc-file`. That part isn't built yet.

### 4.2 Crons in ci.lab

| Name | Schedule | What it does |
| :--- | :--- | :--- |
| `promote-stable` | daily | moves `deploy/canary` to `deploy/stable` once all canary hosts reported healthy for that commit |
| `lock-update` | weekly | updates `flake.lock`, builds everything, opens a PR with the `nvd` diff |

### 4.3 Turn it on (test on the VM first)

The VM is the safest place to watch a rollback happen. Once you trust it:

- **Desktop** (`hosts/desktop/configuration.nix`, already imports the module):
  ```nix
  lab.autoDeploy.enable = true;
  lab.fleetHealth.extraChecks = [ "systemctl is-active --quiet docker.service" ];
  ```
- **Laptop:** add `../../modules/auto-update.nix` to `imports`, then:
  ```nix
  lab.autoDeploy.enable = true;
  ```
- **rpi4:** add `../../modules/auto-update.nix` to `imports`, then:
  ```nix
  lab.autoDeploy = { enable = true; channel = "stable"; flakeAttr = "rpi4"; };
  ```

When `lab.autoDeploy.enable` is on, it replaces the old "stage and ask" daily update on that host.

**Check:**
- `systemctl list-timers auto-deploy.timer` shows the next run.
- After a run, ntfy topic `fleet-health` has `host=... status=ok`.

**Guards:**
- The laptop skips on battery below 30% unless plugged in, and while caffeine is on.
- Any host skips while running the worker specialisation.

---

## 5. Tailscale access rules

**Needs:** a Tailscale API key, or better an OAuth client limited to the policy file.

1. **Copy console edits.** Copy anything you changed by hand in the Tailscale admin console into `tailscale/policy.hujson`. The first apply replaces the whole policy.
2. **Add the key** as the Woodpecker secret `tailscale_api_key`, and allow it on `pull_request` events.
3. **Validate.** Open a PR that touches `tailscale/`. CI checks the policy against the API.
4. **Apply.** Merge. CI applies it.
5. **Tag the nodes** in the admin console:
   - rpi4 gets `tag:orchestrator`.
   - desktop gets `tag:worker`.
   - laptop and phone get `tag:roaming`.

   A bootstrap rule keeps your own devices working while you do this.
6. **Tighten.** Once everything works, remove the bootstrap grant in a follow-up PR.

**Check:** the `tests` block in the policy passes in CI. SSH, Syncthing, Moonlight and lan-mouse still work.

---

## 6. Preview environments for other repos

**Needs:** nothing extra.

1. **Turn it on:**
   - `hosts/desktop/configuration.nix`: `lab.previewEnvs.enable = true;`
   - `hosts/rpi4/configuration.nix`: `lab.previewIngress.enable = true;`
2. **Deploy both.**
3. **Prepare each web project:**
   - Add a `nixosConfigurations.container` output with `boot.isNspawnContainer = true;` and port 80 open.
   - Copy `docs/examples/preview.woodpecker.yaml` into the project's `.woodpecker/`.
4. **Use it.** Open a PR. The preview appears at `https://<name>.dev.lab`, is destroyed on close, and is reaped after 7 days.

**Decide:** the preview CI agent accepts jobs from any repo on your forge. The real gate is that it only builds flakes from `git.lab/justkowal/...`. See `docs/PREVIEW_ENVS.md`.

---

## 7. rpi4 resilience

- **Images:** already on (step 2).
- **Runbook:** read `docs/RPI4_RECOVERY.md` once now, not during an outage. It covers flashing, restoring the host key (sops depends on it), restoring data, and moving root to a USB SSD.
- **USB SSD (optional, recommended):** about 120 to 200 PLN for a SATA SSD plus a UASP adapter. Follow the runbook's SSD section.
- **DNS fallback (decide first):** `lab.dnsFallback.enable = true;` on desktop and laptop keeps DNS working when the Pi dies.

  It turns off Tailscale MagicDNS: short names and `*.ts.net` stop resolving, and lookups stall about 1 s while the Pi is down. Leave it off if you use MagicDNS names.

---

## 8. Streaming that wakes the desktop

**Needs:** an HDMI dummy plug (~30 PLN), or an EDID override. Without either, worker mode has no display to capture.

1. **Turn it on:**
   - `hosts/desktop/configuration.nix`:
     ```nix
     lab.streamHost.enable = true;
     # only if not using a dummy plug; use your real connector name from /sys/class/drm
     lab.streamHost.edidConnector = "HDMI-A-1";
     ```
   - `hosts/rpi4/configuration.nix`: `lab.streamWake.enable = true;`
2. **Deploy both.**
3. **Pair Moonlight** on the laptop or phone with the desktop once, while it's on.
4. **Use it.** Open `https://play.lab`. It wakes the desktop into worker mode, waits for Sunshine, then you connect with Moonlight. In Moonlight, pick "Steam (gamescope)" or "Hyprland".

**Notes:**
- Enabling this makes Sunshine's apps declarative, so the Sunshine web UI can no longer edit them.
- Quit the app in Moonlight rather than just disconnecting. Otherwise the "stream active" marker stays and the desktop won't power off on its own.

---

## 9. Off-peak job runner

1. **Secrets** (`sops hosts/rpi4/secrets/secrets.yaml`):
   - `offpeak_submit_token`: random.
   - `offpeak_ssh_key`: private key from the command below.

   ```bash
   ssh-keygen -t ed25519 -N '' -C offpeak@nixos-rpi4 -f ./offpeak
   ```
2. **Turn it on:**
   - `hosts/rpi4/configuration.nix`: `lab.offpeak.enable = true;`
   - `hosts/desktop/configuration.nix`:
     ```nix
     lab.offpeak.submit.enable = true;
     lab.offpeak.runner.enable = true;
     lab.offpeak.runner.authorizedKey = "<contents of offpeak.pub>";
     ```
   - `hosts/laptop/configuration.nix`: `lab.offpeak.submit.enable = true;`
3. **Prices.** Check the tariff windows and prices in `modules/tariff.nix` against your bill. The prices are placeholders.
4. **Use it:**
   ```bash
   offpeak-submit -d 'tomorrow 07:00' render-scene blender -b scene.blend -a
   ```

   Results go to ntfy topic `offpeak`. Jobs run as the restricted `offpeak` user on the desktop, so they can't touch your files unless you grant access.

---

## 10. Energy cost per job

**Needs:** a Shelly Plug S Gen3 (~80 to 100 PLN, Botland).

1. **Set up the plug.**
   - Add it to Wi-Fi, give it a DHCP reservation, and turn off local RPC authentication in its web UI.
   - Plug the desktop's power strip into it.
2. **Turn it on** in `hosts/rpi4/configuration.nix`:
   ```nix
   lab.energy = { enable = true; shellyHost = "192.168.1.X"; };
   ```
3. **Prices.** Put real prices in `modules/tariff.nix` (`pricePeak`, `priceOffPeak`, gross PLN per kWh, energy plus variable distribution).

**Check:** `shelly_apower_watts` appears in vmui.

On the desktop, this shows the last hour:

```bash
ci-energy-cost $(($(date +%s) - 3600)) $(date +%s)
```

---

## 11. Desk sensors

**Needs:** SCD41 breakout (~200 PLN), BME280 breakout (~40 PLN), Qwiic/STEMMA QT cables. Optionally M2.5 standoffs and DIN 912 M2.5 screws to mount them on the Argon case.

1. **Wire.** Connect both to the Pi's I2C bus 1 (the same bus as the OLED). The BME280 must be at 0x76; if your board is jumpered to 0x77, change `BME280_ADDR` in `hosts/rpi4/sensors.nix`.
2. **Detect.** Check that the addresses show up:
   ```bash
   sudo i2cdetect -y 1
   ```

   Expect 0x3c (OLED), 0x62, 0x76.
3. **Turn it on** in `hosts/rpi4/configuration.nix`: `lab.sensors.enable = true;`

**Check:**
- The OLED shows `CO2 ... C ...%`.
- `desk_co2_ppm` appears in vmui.
- Above 1200 ppm you get an ntfy alert, cleared below 800.

---

## 12. Laptop and desktop handoff

1. **Pin the desktop's address.** Give the desktop a DHCP reservation on the router. Tailscale can't reliably report its LAN address.
2. **Pair KDE Connect** between the two, and set up the lan-mouse edge once in `lan-mouse-gui` on both.
3. **Turn it on** in `home/default.nix`, next to `lab.rooms.enable`:
   ```nix
   lab.handoff.enable = true;
   # laptop only; use the reserved address
   lab.handoff.peerAddress = lib.mkIf laptop "192.168.1.X";
   ```
4. **Optional audio:** add `lab.handoff.audioSink.enable = true;` so the laptop plays through the desktop speakers. Also open TCP 4713 on the desktop:
   ```nix
   networking.firewall.allowedTCPPorts = [ 4713 ];
   ```
5. **Rebuild both.**

**Check:** at home, `systemctl --user is-active home-lan.target` prints `active`. The mouse crosses screens and the clipboard syncs. Away from home, it all stops by itself.

Use `home-lan toggle` to pause it, not the switch in `lan-mouse-gui`.

---

## 13. Finishing touches for focus mode

These need edits I left for you, because they touch shared files:

1. **Quiet ntfy during focus.** In `hosts/desktop/configuration.nix`, inside `ntfy-listener`, replace the `notify-send` line with:
   ```sh
   if /etc/profiles/per-user/justkowal/bin/focus gate "$priority"; then
     notify-send -u "$urgency" -a "Homelab" "$title" "$message"
   fi
   ```

   Priority 4 and above still gets through.
2. **Waybar modules.** In `home/waybar.nix`, add:
   ```nix
   "custom/focus" = { format = "{}"; return-type = "json"; exec = "focus waybar"; interval = 15; on-click = "focus toggle"; };
   "custom/handoff" = { format = "{}"; return-type = "json"; exec = "home-lan waybar"; interval = 10; on-click = "home-lan toggle"; };
   ```

   Then add them to `modules-right`, and add `#custom-focus, #custom-handoff` to the shared style rule.
3. **OpenRGB profiles.** In OpenRGB on the desktop, create profiles named `focus` and `default`.

---

## 14. Battery thresholds

The schedule is on. To make "not travelling" mean 75 to 80% instead of TLP's current 90%, change these in both `hosts/laptop/configuration.nix` and `modules/power-saving.nix` (inside the `mkForce` block):

```nix
START_CHARGE_THRESH_BAT0 = 75;
STOP_CHARGE_THRESH_BAT0 = 80;
```

**Use it:** put "travel" in a calendar event's title, category or location for the day you leave.

---

## 15. Desktop widgets

The widgets are on after step 1 on both machines: a column above the wallpaper (top right, visible on empty workspaces) and a dashboard on `SUPER + W` (Esc or a click outside closes it, `R` refreshes everything). Sections without data stay hidden on the wallpaper column and show their error on the dashboard. A few need one-time setup:

1. **Woodpecker CI.** In ci.lab, open your user settings, then Personal access token, and copy it. Add it to sops:
   ```bash
   sops hosts/rpi4/secrets/secrets.yaml
   ```

   Key: `woodpecker_widget_token`. Then declare it readable by you in both `hosts/desktop/configuration.nix` and `hosts/laptop/configuration.nix`, inside the `sops` block:
   ```nix
   secrets."woodpecker_widget_token".owner = "justkowal";
   ```

   Rebuild both. Without it the CI section says "no token".
2. **GitHub.** Log in once on each machine:
   ```bash
   gh auth login
   ```

   Or skip it with `lab.widgets.disabled = [ "github" ];` in `home/default.nix`.
3. **Claude and Gemini limits.** The widget reads the tokens Claude Code (`~/.claude/.credentials.json`) and Antigravity (`~/.gemini/jetski-standalone-oauth-token`) already store. It never refreshes them itself, because refreshing would rotate the token and log those apps out. If you haven't opened an app for a while, its section falls back to a local estimate (Claude tokens from your transcripts, Gemini session counts) and says why. Both quota endpoints are unofficial, so expect the occasional break.
4. **Location.** Weather and air quality default to Kraków. Change it in `home/default.nix`:
   ```nix
   lab.widgets = { lat = 52.23; lon = 21.01; place = "Warszawa"; };
   ```
5. **Which sections sit on the wallpaper** is `lab.widgets.desktop` (a list, top to bottom), and `lab.widgets.monitors = [ "DP-1" ];` limits the column to some screens.

**Check it:** run every provider once and read the JSON; each failing one has an `error` field:

```bash
deskwidgets --dump
```

The service is `systemctl --user status deskwidgets`. On battery every poll runs 3x less often.

---

## 16. Root wipe and snapshots (do last)

Do this only after step 3, with at least one verified backup of each machine.

1. **Read** `docs/IMPERMANENCE_MIGRATION.md` fully.
2. **Migrate the laptop first** (btrfs, better tested): boot the ISO, create `@root @root-blank @nix @persist @home`, copy data with reflinks, and write the password file.
3. **Desktop (bcachefs):** first add `boot.supportedFilesystems = [ "bcachefs" ];` to `hosts/iso/configuration.nix` and rebuild the ISO.
4. **Enable on that host:**
   ```nix
   lab.impermanence = {
     enable = true;
     iUnderstandRootIsWiped = true;
     layout = { fsType = "btrfs"; device = "/dev/mapper/cryptroot"; };
   };
   lab.snapshots.enable = true;
   ```
5. **First boot is not wiped.** Run this and read every line:
   ```bash
   lab-impermanence-diff
   ```
6. **Arm the wipe:**
   ```bash
   sudo touch /persist/.lab-impermanence-armed
   ```

**Know before enabling:**
- `passwd` stops working; passwords come from `/persist/passwords/justkowal`.
- Old roots are kept under `@old_roots` (last 5), so a bad wipe is recoverable.

**Snapshots:** run `timemachine-gui` from the launcher, or use "Browse snapshots" in Dolphin. It works once `/home` is a subvolume.

---

## Appendix: everything you need to create

**sops keys** (`hosts/rpi4/secrets/secrets.yaml`):
- `restic_nixos-desktop_password`
- `restic_thinkpad-t14s-gen1-amd_password`
- `restic_nixos-desktop_rest_password`
- `restic_thinkpad-t14s-gen1-amd_rest_password`
- `restic_server_htpasswd`
- `restic_offsite_password`
- `restic_offsite_ssh_key`
- `offpeak_submit_token`
- `offpeak_ssh_key`
- `woodpecker_widget_token` (a personal token from ci.lab, section 15)

**Woodpecker secrets** (repo `justkowal/nixos-configs`):
- `cache_push_key`
- `forgejo_deploy_token`
- `forgejo_bot_token`
- `tailscale_api_key`
- `dr_restic_repository`
- `dr_restic_password`
- optional: `dr_forgejo_token`, `dr_paperless_token`

**Woodpecker crons:** `dr-drill` (monthly), `promote-stable` (daily), `lock-update` (weekly).

**Forgejo:** a push webhook to `http://nixos-rpi4.lab:9100/hooks/wake-worker`, plus the two tokens.

**Hardware (approx. gross):**

| Item | Section | Price |
| :--- | :--- | ---: |
| Shelly Plug S Gen3 | 10 | 80 to 100 PLN |
| SCD41 + BME280 + cables | 11 | ~255 PLN |
| HDMI dummy plug | 8 | ~30 PLN |
| USB SSD + UASP adapter | 7 | 120 to 200 PLN |

## What has not been tested on real hardware

All of it evaluates and the scripts pass shellcheck/ruff, and the impermanence wipe passed VM tests. These parts will most likely need a fix on first contact:

- the DR drill probes
- Sunshine headless capture
- the Blocky focus API calls
- `tlp setcharge` through polkit
- the Shelly and sensor reads
- the Tailscale policy (until CI validates it)
- the first real auto-deploy rollback
- the widget's Claude and Gemini quota calls (both tokens were expired during testing, so only the local fallback ran) and the Woodpecker API (no token yet)

Watch ntfy and `journalctl` the first time each one runs.
