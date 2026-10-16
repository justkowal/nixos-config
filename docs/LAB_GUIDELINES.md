# Lab Guidelines

Source of truth for how the desk looks, behaves and is wired. Read this before adding or changing anything in `home/`, `hosts/*/scripts/` or any UI script. `CLAUDE.md` at the repo root points here.

The desk layer is called **Kowal Lab** ("Lab" in short). The module namespace is `lab.*`. The name is settled; do not rename it.

## 1. Vision

Lab is one layer with five surfaces and one nervous system.

| Surface | Job | Today | Target |
| :--- | :--- | :--- | :--- |
| **Island** | Every state change | none, `notify-send` and swayosd | top-centre morphing surface in `labd` |
| **Palette** | Every action, from the keyboard | Rofi pickers | `SUPER + SPACE` in `labd` |
| **Scenes** | Named desk states that change everything at once | manual scripts | `arrive`, `focus`, `leave`, `present`, `sleep` |
| **Light and sound** | Ambient output of the same state | OpenRGB on focus only | LED glyph layer, short sound set (on by default) |
| **Continuity** | State follows you between machines | handoff only | device roster, room transfer, phone PWA |

The nervous system is the state bus. Publishers write events, subscribers render them. Nothing renders state directly from another tool.

Design references: Apple for hierarchy, motion and one anchor point; Nothing for a restrained monochrome base, dot-matrix numerals, one accent and light as an interface.

Lab is not: a second bar, a new broker, a theme engine that replaces Matugen, or decoration for its own sake.

## 2. Visual rules

- **Tokens only.** UI files never contain raw px radii, hex colours or font family names. Read them from the token module (`home/lab/design.nix`). Reason: one token change must reach every surface, or the desk looks like several products again.
- **Colour comes from Matugen.** Only colour roles change with the wallpaper. Radii, type, spacing and motion are fixed. Reason: a wallpaper change should alter colour and nothing else.
- **One motion set.** One spring for surfaces entering, one fade for idle transitions. No bounce on data. Reason: consistent timing is most of what reads as "premium".
- **One icon and glyph set.** Lucide or SF-style SVG in chrome. No Nerd Font glyphs in UI chrome, no emoji anywhere in UI. Nerd Font glyphs stay allowed in terminal prompts only.
- **Contrast.** Text on the island and palette meets WCAG AA against light and dark wallpapers.
- **Sound is on by default.** Short sounds play on scene change and handoff only, never on routine state. Every sound has a mute path (a token, and the system mute). Reason: sound is part of the product, but it must never nag.
- **Reduced motion and text scale** are tokens. Every emitter reads them. A new animation without a reduced-motion path is not done.
- **OLED-safe.** Dark base on OLED hardware, no static bright pixels, slow pixel shift on the rpi4 OLED.
- **Radii are continuous.** Use the token radius classes, never a one-off value.

## 3. Interaction rules

- **The island is the only state presenter.** Volume, brightness, focus, room, handoff, CI, battery and notifications appear there. Reason: one place to look, one motion, one queue.
- **CLIs publish, they do not render.** A script that changes state publishes an event to the bus. It never calls `notify-send` for state and never starts its own OSD. Reason: presentation decisions belong to one process.
- **Every action is reachable from the palette.** If a feature has a keybind, it also has a palette entry. Reason: the palette is the discoverable surface.
- **Keyboard first.** Every surface works without a mouse. Mouse support is additive.
- **Every feature declares three hooks:** a keymap entry, a palette entry and a scene hook (even if the scene hook is "not used by a scene" with a reason).
- **Destructive or irreversible actions** (power off, reboot, delete a room) confirm in the island or palette, never silently.

## 4. Architecture rules

- **Namespace.** Every feature is a Nix module under `lab.<feature>` with its options in `options.lab.<feature>`, as `home/rooms.nix`, `home/focus.nix` and `home/handoff.nix` already do. Use `lib.mkEnableOption` for the enable flag.
- **Nix first.** Behaviour and configuration are declared in Nix. Shell and Python scripts are the implementation, embedded with `builtins.readFile` as `home/rooms.nix` does. Do not hand-write config that Nix can generate.
- **State bus contract.** Events are newline-delimited JSON with these fields:
  - `name`: dotted lowercase, for example `focus.on`, `room.restored`, `handoff.arrived`.
  - `source`: the publisher, for example `room`, `focus`, `home-lan`.
  - `payload`: small JSON object. No large blobs, no file contents.
  - `priority`: `low`, `normal` or `high`. `high` may interrupt the island queue.
  - `ttl`: seconds after which the event is stale and must not be shown.
- **Subscribers do not poll what the bus publishes.** If the data exists as an event, subscribe. Polling is for providers that have no event source (weather, CI, GitHub).
- **Providers run on worker threads.** The GTK main loop never blocks on I/O, subprocesses or network. Reason: a frozen shell is the most visible failure a desk can have. The existing pattern is `home/scripts/guis/widgets_providers.py`.
- **`app_id` is declared on every layer-shell and GTK window.** Use the `lab.justkowal.<Name>` pattern already used by `lab.justkowal.Widgets`. Window rules in Hyprland match on it.
- **No new daemon unless the bus cannot do the job.** The bus is the daemon. A second long-running process needs a written reason in its module comment.
- **Hyprland binds are generated** from `home/lab/keymap.nix` once it exists. Until then, add binds next to the feature's module and list them in `docs/DESKTOP_ENVIRONMENT.md`.
- **Secrets** go through `sops-nix` (`hosts/rpi4/secrets/secrets.yaml` is the existing pattern). Never commit tokens or `.env` files.

## 5. Add-a-feature checklist

Work through this list in order. Do not skip the last two.

1. Create `home/<feature>.nix` with `options.lab.<feature>.enable` and a `config = lib.mkIf cfg.enable {...}` block.
2. Name the bus events it publishes, following section 4. Write the publisher CLI so it only publishes.
3. Name the island state(s) it uses. If none fits, the feature is not designed yet; design the state first.
4. Add a palette entry and a keymap entry.
5. Decide scene participation: which scenes call it, and whether it changes the LEDs or sound.
6. Map the feature to a glyph and, if it plays a sound, to a sound name from the set.
7. Use tokens for every colour, radius, font and motion value.
8. Run `nix flake check` with new files staged (`git add`), since flakes ignore untracked files.
9. Add a `lab doctor` check for the feature once `lab doctor` exists.
10. Update `docs/DESKTOP_ENVIRONMENT.md` or the generated keybind section.

## 6. Anti-patterns

- Hard-coded colours, radii or fonts in a UI file.
- `notify-send` used for state.
- A second OSD, a second bar, a second notification panel.
- A script that polls something the bus already publishes.
- A feature that exists only in a README and has no palette entry.
- A new long-running process with no written reason.
- Blocking the GTK main loop with a subprocess or network call.
- Bounce, parallax or glow effects on data.
- Emoji or Nerd Font glyphs in UI chrome.
- Animations with no reduced-motion path.

## 7. Voice

- Sentence case for every label. Lowercase only for the wordmark.
- Short labels, two or three words where possible.
- Nouns for states ("Focus on", "Room saved", "Handoff complete"). Verbs for actions ("Restore room", "Start focus").
- No exclamation marks. No "Oops", no "Successfully".
- Errors state what failed and what to do next ("CI unreachable, showing last result").

## 8. Verification

Run what applies to the files you touched.

```bash
# Nix: evaluate and check the flake (stage new files first)
git add -A home/ hosts/ modules/ docs/
nix flake check

# Build one host without switching
nh os build .

# Python GTK and provider scripts
python -m py_compile home/scripts/guis/*.py

# Shell scripts
shellcheck home/scripts/*.sh

# Desk health, once `lab doctor` exists
lab doctor
```

Visual changes need a screenshot check: trigger the state, capture with `grim`, and compare against the previous capture. Once the VM screenshot test exists, it is the reference.

## 9. Current state

- The shell process is `deskwidgets` (`home/widgets.nix`, `home/scripts/guis/widgets_gui.py`). It is the seed for `labd`.
- Waybar, SwayNC and Rofi are still the main bar, notification centre and palette. They stay as working fallbacks until the owner has verified the replacements on real hardware. Do not remove or break them, and do not delete their Nix modules, even after the replacements ship.
- The phone PWA is in scope. It is served through the rpi4 ingress (`hosts/rpi4/ingress.nix`) and reads the same state bus events and tokens as the desktop.
- The OSD wrappers `home/scripts/volume-osd.sh` and `home/scripts/brightness-osd.sh` are legacy. Do not add to them.
- Matugen templates in `home/matugen/templates/` are the colour source and stay that way.
