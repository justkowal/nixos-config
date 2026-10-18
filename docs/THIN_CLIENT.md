# Thin client mode

A second boot entry for the laptop that only shows the desktop. It is built for battery life and has almost nothing running, but it keeps the Lab look: the island, the palette, the bar, the tokens.

It is a separate configuration (`hosts/laptop/thin-client.nix`, attached to the laptop as `specialisation.thin-client` with `inheritParentConfig = false`), not the normal laptop with services switched off. It shares the disk and the boot chain (LUKS with TPM2, Lanzaboote), the hostname, the Tailscale node and your user. Everything else is its own.

## Using it

1. `nh os boot` on the laptop (or `nh os switch`), reboot, and pick `thin-client` in the boot menu. The normal entry is still there, so going back is a reboot.
2. Log in at the greeter. It starts **labwc**, a very small wlroots compositor, with `labd` (the island) and a small bar. The greeter also offers a second session, **Stream direct (no compositor)**, see below.
3. First time only: pair Moonlight with the desktop (`moonlight pair nixos-desktop.lab` in a terminal, enter the PIN in Sunshine on the desktop).
4. `SUPER + M` (or the palette entry "Stream the desktop") wakes the desktop if it sleeps, with the spinner, check and dot toast, then opens the Moonlight stream of the Sunshine app `Desktop`.

| Key | Does |
| :--- | :--- |
| `SUPER + SPACE` | the command palette |
| `SUPER + M` | wake and stream the desktop |
| `SUPER + RETURN` | a terminal (`foot`) |
| `SUPER + Q` | close the window |
| volume, mute, brightness keys | change it and show it in the island |

The palette (`lab-thin entries`) carries the few utilities there are: join a Wi-Fi network (type its name, known networks connect at once, a new secured one opens `nmtui-connect` for the password), network setup (`nmtui`), tailnet status (the device roster in the island), audio output and input routing, a terminal, suspend, reboot and power off. Every other app on the desktop is one palette entry away through "Run on Desktop".

## What runs

Network stack (NetworkManager with Wi-Fi power saving, Tailscale), PipeWire, UPower, TLP, greetd, labwc, `labd`, and the accubattery daemon. No Syncthing, no widgets, no Waybar or SwayNC, no AI daemons, no fingerprint reader, no Bluetooth, no firmware updater, no documentation. The kernel is the lean tickless low power one that `modules/kernel-powersave.nix` already builds for the ultra-low-power profile, and every boot parameter and TLP setting of that profile is applied permanently.

## Drawing straight to the screen

Under labwc a fullscreen Moonlight window is scanned out directly by the display hardware as long as nothing is drawn over it, so the compositor does no composition work. The **Stream direct** session goes one step further and uses no compositor at all: `moonlight-qt` runs on Qt's EGLFS/KMS platform and its DRM renderer puts decoded video frames onto a display plane. It starts a wake-up of the desktop, then retries the stream for three minutes. The island and the bar do not exist there (they need a compositor), and the way back is a reboot or switching to another console and logging in again. Treat it as experimental.

## Status

Evaluates and builds from the flake; not yet booted on the laptop. Things to check on first boot: the labwc autostart (`~/.config/labwc/autostart`) brings up `labd`, the bar is visible, Moonlight pairs and streams, the direct session finds the display, and the power draw. Measure with `powertop` and the accubattery readout, and write the numbers below.

| Mode | Idle, screen dim | Streaming |
| :--- | :--- | :--- |
| normal laptop | not measured | not measured |
| thin client | not measured | not measured |

## Open questions

- Whether Moonlight or Peek windows should be the main path (Peek shows single windows, Moonlight the whole desktop).
- What should stay usable when the desktop is unreachable (a browser, a terminal), and whether a fingerprint login is worth the service.
- The Wi-Fi password step opens a terminal; a small dialog on the palette would be nicer.
