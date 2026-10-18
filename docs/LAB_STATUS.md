# Lab status

State of the Kowal Lab layer on 2026-10-18, branch `perf-benchmarks`. The rules live in [LAB_GUIDELINES.md](LAB_GUIDELINES.md), this file says what exists, what is switched on and what still needs a person.

## Built and in use

| Part | Where | Notes |
| :--- | :--- | :--- |
| State bus, island, palette, help window | `pkgs/labd`, `home/lab/{shell,palette,help}.nix` | Rust, socket at `$XDG_RUNTIME_DIR/lab.sock`. `SUPER + SPACE` palette, `SUPER + /` help. |
| Design tokens | `home/lab/design.nix` | Inter, Departure Mono, JetBrainsMono Nerd Font. Colour from Matugen only. Lint: `checks.tokens`. |
| Keymap as data | `home/lab/keymap.nix` | Generates Hyprland binds, `lab keys`, the help window. |
| Scenes, sound, LEDs | `home/lab/{scenes,led}.nix`, `lab scene` | arrive, focus, leave, present, sleep. |
| Rooms, focus, handoff | `home/{rooms,focus,handoff}.nix` | Publish to the bus; the island presents. Focus does not block YouTube. |
| Device roster, room transfer | `home/lab/roster.nix`, `home/scripts/lab-inbox.py` | Taildrop. Tagging a device breaks Taildrop, do not tag. |
| Phone and tablet app | `pkgs/labd/src/phone.rs`, `home/lab/phone.nix` | Tailnet only, bearer token, `lab phone --copy`. Setup: [ANDROID_SETUP.md](ANDROID_SETUP.md). |
| Lock screen | `home/hyprland.nix` | Tokens and Matugen colours. |
| Login greeter | `modules/lab-greeter.nix` | tuigreet, shared by laptop and desktop. |
| Continuity | `home/lab/continuity.nix` | Fleet focus follows the hub on every machine, notifications and the fingerprint wait toast are mirrored over Taildrop. Needs `lab-inbox` and Taildrop on both machines. |
| Peek | `home/lab/peek.nix` | Use a window of your other machine like a local one: palette entry, window-locked GPU encoded video, full mouse and keyboard passthrough, dialogs as their own windows, small badge. |
| Run on desktop | `lab run`, palette "Run on <Machine> · <App>" | Wakes the other machine if needed, shows a spinner, check and dot toast, then opens the app there. |
| Clipboard sharing | `home/lab/continuity.nix` | Copied text follows you between the laptop and desktop. `lab clip toggle` pauses it. |
| Theme packs | `home/lab/theme.nix`, `lab theme` | Lab, Dot matrix, Soft. `SUPER + ALT + C` cycles. |
| rpi4 hub | `hosts/rpi4`, [DEPLOYMENT.md](DEPLOYMENT.md) | Deployed. Focus hooks, Blocky DNS, paperless fixes. |

## Built but off

| Part | Switch | Why off |
| :--- | :--- | :--- |
| labd bar and tray | `lab.bar.enable = true` (`lab.bar.default = "labd"` to start with it) | Needs a live check of Pomodoro, Caffeine, thinkdot, backlight, media, tray with a real app, and the Departure Mono sharpness. Waybar stays the fallback. |
| Boot splash | `lab.boot.splash.enable = true` | Never run on hardware. Try the desktop first. The laptop is LUKS2 + TPM2 with a systemd initrd, so check it boots cleanly before enabling there. |

Waybar and SwayNC stay installed and are the default until the owner has verified the replacements.

## Not done

- Pi OLED mirror of the island: the screen was unavailable.
- Visual regression VM test for island states: the headless labwc + grim harness was only used by hand, it is not a flake check.
- Tablet is not yet on Tailscale, so the phone app has not been used from it.

## Needs a person

1. Switch both machines: `nh os switch /etc/nixos`, then `systemctl --user restart labd` if the island is missing.
2. Walk through [ANDROID_SETUP.md](ANDROID_SETUP.md) for the phone and tablet.
3. Decide on `lab.handoff.enable`, streaming wake (HDMI dummy plug) and applying `tailscale/policy.hujson`.
4. Try the bar and the splash as described above, then decide whether Waybar and SwayNC can go.
5. Fix the unused `ICalGLib` import in `pkgs/accubattery/scripts/events.py`, it fails the flake `scripts` check (not Lab code).

## Known limits

- A theme pack changes labd surfaces and Matugen colours. Waybar radii are baked at build time. After changing base tokens in Nix, run `lab theme NAME` again, the merged file in `~/.local/state/lab/` wins until then.
- labd and Waybar both want `org.kde.StatusNotifierWatcher`. Stop Waybar before using the Lab bar tray.
- `labd` retries without a start limit, so a compositor restart no longer leaves it dead. Logs: `journalctl --user -u labd`.
- Sandbox notes for anyone testing remotely: ssh needs `-F /dev/null`, and `nixos-rebuild` needs `NIX_SSHOPTS="-F /dev/null -o BatchMode=yes"`.

## Planned

- **Thin client mode** for the laptop: a NixOS specialisation (`thin-client`) that turns the ThinkPad into a battery-first window onto the desktop. Ideas to settle before building it:
  - A different, lean kernel (no XanMod tuning for gaming, power-saving defaults, only the modules this machine needs) and the smallest set of services: network stack and Tailscale, a very small Wayland compositor (cage, labwc or a trimmed Hyprland), Moonlight, `labd` with the island, and the accubattery daemon. No Syncthing, no widgets, no AI daemons, no background indexing.
  - Everything tuned for battery: CPU governor and EPP, AMD GPU power states, screen refresh and brightness policy, Wi-Fi power save, wake-up sources, suspend that resumes straight into the stream. Measure it (`powertop`, accubattery) and keep the numbers in this file.
  - Waking and finding the desktop is the core path: `lab run desktop` already wakes it and shows the toast, the thin client would boot into that flow and open the Moonlight session (or Peek windows) without a launcher.
  - The design language stays: tokens, Matugen colour, the island and the bar (labd only, no Waybar or SwayNC), drawn glyphs. Minimal means fewer services, not a different look.
  - Open questions: single specialisation versus a separate host config, how the specialisation is chosen at boot (systemd-boot entry), whether Moonlight or Peek is the primary path, and what stays local (browser, terminal) when the desktop is unreachable.
