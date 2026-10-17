# Lab Guidelines

Source of truth for how the desk looks, behaves and is wired. Read this before adding or changing anything in `home/`, `hosts/*/scripts/` or any UI script. `CLAUDE.md` at the repo root points here.

The desk layer is called **Kowal Lab** ("Lab" in short). The module namespace is `lab.*`. The name is settled; do not rename it.

## 1. Vision

Lab is one layer with five surfaces and one nervous system.

| Surface | Job | Today | Target |
| :--- | :--- | :--- | :--- |
| **Island** | Every state change | none, `notify-send` and swayosd | top-centre morphing surface in `labd` |
| **Palette** | Every action, from the keyboard | `SUPER + SPACE` in `labd` (apps, rooms, actions); Rofi still on `SUPER + D` | more sources: clipboard, fleet, scenes, AI |
| **Scenes** | Named desk states that change everything at once | manual scripts | `arrive`, `focus`, `leave`, `present`, `sleep` |
| **Light and sound** | Ambient output of the same state | OpenRGB on focus only | LED glyph layer, short sound set (on by default) |
| **Continuity** | State follows you between machines | handoff only | device roster, room transfer, phone PWA |

The nervous system is the state bus. Publishers write events, subscribers render them. Nothing renders state directly from another tool.

Design references: Apple for hierarchy, motion and one anchor point; Nothing for a restrained monochrome base, dot-matrix numerals, one accent and light as an interface.

Lab is not: a second bar, a new broker, a theme engine that replaces Matugen, or decoration for its own sake.

## 2. Visual rules

- **Tokens only.** UI files never contain raw px radii, hex colours or font family names (the lint flags `font-family:` followed by a literal name, so write `font-family: "${ui}"` or a placeholder, never `"Inter"`). Read them from the token module (`home/lab/design.nix`). Reason: one token change must reach every surface, or the desk looks like several products again.
- **Faces are Inter (UI) and Departure Mono (clock digits and big numbers), plus JetBrainsMono Nerd Font for terminal and glyph fallback.** Every face a token names must be installed (`home/lab/design.nix` installs Inter and Departure Mono). The first version named Outfit, which exists nowhere on the system, so the bar, widgets and island all silently fell back to different fonts. When you change a font token, check `fc-match "<name>"` returns that font.
- **One item shape on the bar and every surface:** no chip fill, a soft `on_background` hover at 8 percent, accent only for state (active workspace, playing media, active toggles) and `error` or `tertiary` for warnings. Do not give status items their own colours.
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
- **Language split.** Rust for long-running, latency-sensitive Lab processes: the bus and everything that draws on the compositor (`pkgs/labd`, gtk4-rs + libadwaita + gtk4-layer-shell). Python and shell for providers, CLIs and glue. Reason: no GIL stalls under animation, low idle memory, a typed event contract where it matters. The wire formats (bus JSON, `tokens.json`, `keymap.json`) stay language-neutral, so either side can be replaced alone.
- **Providers run on worker threads.** The GTK main loop never blocks on I/O, subprocesses or network. Reason: a frozen shell is the most visible failure a desk can have. The existing pattern is `home/scripts/guis/widgets_providers.py`.
- **`app_id` is declared on every layer-shell and GTK window.** Use the `lab.justkowal.<Name>` pattern already used by `lab.justkowal.Widgets`. Window rules in Hyprland match on it.
- **No new daemon unless the bus cannot do the job.** The bus is the daemon. A second long-running process needs a written reason in its module comment.
- **Lab binds go through `lab.keymap.entries`** (`home/lab/keymap.nix`: `mods`, `key`, `exec`, `group`, `label`). It renders the Hyprland `bind` line and `~/.config/lab/keymap.json` (`lab keys` prints it), and fails evaluation on a duplicate mods+key. Do not write raw `bind =` lines for Lab features. `$mod` in an entry is rewritten to `SUPER` on render: Hyprland only defines `$mod` partway down `home/hyprland.nix`, so a generated line from an earlier-imported module that kept `$mod` registered as ALT only (this shipped once, SUPER+ALT+P, R and D were really ALT+P, R and D). Older binds in `home/hyprland.nix` migrate over time.
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

# Rust (labd): needs gtk4, libadwaita, gtk4-layer-shell, pkg-config
nix-shell -p cargo rustc rustfmt clippy pkg-config gcc gtk4 libadwaita gtk4-layer-shell glib \
  --run 'cd pkgs/labd && cargo fmt --check && cargo clippy && cargo test'

# Python GTK and provider scripts
python -m py_compile home/scripts/guis/*.py

# Shell scripts
shellcheck home/scripts/*.sh

# Desk health, once `lab doctor` exists
lab doctor
```

Visual changes need a screenshot check: trigger the state, capture with `grim`, and compare against the previous capture. Once the VM screenshot test exists, it is the reference.

## 9. Current state

- **Foundations are in.** Tokens: `home/lab/design.nix` (`config.lab.design.tokens` in Nix, `~/.config/lab/tokens.json` at runtime). Token lint: `ci/lint-tokens.sh`, a flake check; files that predate it are in `ci/token-baseline.txt`, which may only shrink (remove a file from it when you clean it up). CLI: `lab publish|status|watch|keys|doctor` (`home/scripts/lab.py`, client in `home/scripts/guis/lab_bus.py`). Publishing is best effort and exits 0 when the shell is down unless `--strict`.
- **`labd` (Rust, `pkgs/labd`, service in `home/lab/shell.nix`) owns the bus** on `$XDG_RUNTIME_DIR/lab.sock` and draws the island (`src/island.rs`). Add a new island state in `card_for` in `island.rs`: map the event name to icon, text, optional level and hold time. Events with no mapping are ignored on purpose. The event contract lives only in `src/bus.rs` (`make_event`). Publish with `lab publish` (or `lab-publish`, the compiled client in `src/bin/lab-publish.rs`, fast enough for key repeat). Python code that needs the bus uses `lab_bus.py` (client only).
- **Palette today** (`pkgs/labd/src/palette.rs`, `SUPER + SPACE`, sent as the `palette.toggle` bus event): sources are `~/.config/lab/palette.json` (`{search, entries}`, generated by `home/lab/palette.nix` from every keymap entry plus `lab.palette.entries`), saved rooms and git repos (`room entries`, fetched on a worker thread each time it opens), and desktop apps. A last row, "Search the web for ...", follows the typed text and always ranks below real matches, so it is what Enter does when nothing else matches (template `lab.palette.searchUrl`, default Google). Saving a workspace needs no terminal: typing any text adds a row "Save this workspace as room <name>" below the web row, and typing `save <name>` puts it first together with "Save all workspaces as room <name>" (it says "Overwrite room" when the name exists). Names are reduced to `[A-Za-z0-9._-]` (`room_name` in `palette.rs`) because they become file names and travel through Taildrop. Row ordering lives in the pure `rank` function and is unit tested. Everything runs through `hyprctl dispatch exec` so launched programs live in the compositor session, never in labd's service cgroup (a labd restart must not kill your apps). Actions with `confirm = true` need a second Enter. Rofi is still bound to `SUPER + D` as the fallback until you verify the palette.
- **To add a palette action:** keymap entries appear automatically (set `palette = false` to hide one). Anything without a key goes in `lab.palette.entries` (`title`, `group`, `exec`, optional `confirm`, `glyph`). To add a new source (clipboard, fleet), add a loader in `palette.rs` next to `room_items` and run slow ones off the main loop.
- **Shared motion:** `src/motion.rs` is the one spring (tokens `motion.spring`) used by both surfaces; new surfaces animate a 0..1 progress through it instead of making their own animation.
- **Scenes** (`home/lab/scenes.nix`, run by `lab scene NAME`, listed in the palette as "Scene: <title>"): data with `title`, `steps` (shell commands, a failing step does not stop the scene), `on` (bus events that start it) and `announce` (show a card; leave off when the steps already show their own state). Defaults: `arrive` (no steps, `on = []`, opt in with `lab.scenes.arrive.on = ["handoff.arrived"]`), `focus` (`focus on 25`), `leave` (`room save last --all`, `focus off`, lock). `lab scene` publishes `scene.started` and `scene.done`. labd starts scenes from `on` (never from events whose source is `scene`, with a 5 s per-scene debounce), see `src/engine.rs`.
- **Sound** (`src/engine.rs`, on by default, `lab.design.soundEnabled` and system mute turn it off): only `scene.done` (arrive, leave or the generic scene sound, none when a step failed) and `handoff.arrived` play, through `canberra-gtk-play` with the freedesktop names in the tokens `sound` map. Never add sound to routine state.
- **LED layer** (`home/lab/led.nix`, `home/scripts/lab-led.py`, service `lab-led`, enabled where `lab.focus.openrgb.enable` is): loads OpenRGB profiles from bus events using `lab.led.profiles` (`event` or `event:payload-name` to profile). Defaults map `focus.on` and `focus.off` to the focus and default profiles. `focus.sh` no longer talks to OpenRGB, it only publishes. Not run against real hardware yet, only against a fake client.
- **Glyphs are drawn, not themed.** `pkgs/labd/src/glyphs.rs` draws every island icon with cairo in a 24x24 box (round caps, 1.75 stroke), so nothing depends on the active icon theme (the first version used theme icon names and focus mode rendered blank). Add a state's glyph there and reference it from `card_for`. Preview the set with `LAB_GLYPH_SHEET=/tmp/glyphs.png cargo test glyph_sheet -- --ignored` (inside the nix-shell from section 8) and look at the PNG.
- The island sits below Waybar while Waybar exists, because layer-shell respects its exclusive zone.
- `deskwidgets` (Python) still draws the dashboard and wallpaper column. It is a bus client candidate, not the bus owner.
- Waybar and SwayNC stay as working fallbacks until the owner has verified the replacements on real hardware. Do not remove them or their Nix modules, even after the replacements ship. They are restyled from the tokens (`home/waybar.nix`: one item shape, accent for state only, shared screen edge from `space`, tray `icon-size` and `spacing`), and `deskwidgets` reads `tokens.json` for fonts and radii, uses the display face for the clock and big numbers, an accent colon in the clock, and the same screen edge plus one inset. Both are off the lint baseline; what remains in `ci/token-baseline.txt` are the GTK tool windows (control center, fleet manager and similar) and `home/ai.nix`.
- The phone PWA is in scope. It is served through the rpi4 ingress (`hosts/rpi4/ingress.nix`) and reads the same state bus events and tokens as the desktop.
- The OSD wrappers `home/scripts/volume-osd.sh` and `home/scripts/brightness-osd.sh` are legacy. Do not add to them.
- Matugen templates in `home/matugen/templates/` are the colour source and stay that way.

## 10. Event catalog

Add a row here when you add an event. Payload keys are the contract between publisher and `card_for` in `island.rs`.

| Event | Source | Payload | Island |
| :--- | :--- | :--- | :--- |
| `volume.changed` | `volume-osd` | `value` (percent, may exceed 100), `muted` | icon, "Volume" or "Muted", level bar |
| `mic.changed` | `volume-osd` | `muted` | "Microphone muted" or "active" |
| `brightness.changed` | `brightness-osd` | `value` (percent), `monitor` | "Brightness", level bar |
| `focus.on` | `focus` | `minutes` (string) | "Focus on" |
| `focus.failed` | `focus` | `reason` | "Focus unavailable, <reason>" (high priority), when the hub rejects or does not answer |
| `focus.off` | `focus` | `ended` (only when it ended elsewhere) | "Focus off" |
| `room.saved` | `room` | `name`, `windows` | "Room saved, <name>" |
| `room.restored` | `room` | `name`, `windows` | "Room restored, <name>" |
| `handoff.arrived` | `home-lan` | `peer`, `ip` | "Handoff complete, <peer>" |
| `handoff.left` | `home-lan` | `peer` | not shown (kept for scenes) |
| `roster.changed` | `roster` | `devices` (`host`, `title`, `kind`, `os`, `online`, `self`) | stored by the island, not shown |
| `roster.show` | `keymap` | none | "Devices" with a dot per device (filled online, ring offline), `SUPER + ALT + D` |
| `roster.device` | `roster` | `title`, `online` | "<title> connected" or "offline" |
| `room.sent` | `room` | `name`, `peer` | "Room sent to <peer>" |
| `room.received` | `lab-inbox` | `name`, `from`, `windows` | "Room received, <name> from <from>" for 8 s (high priority), plus a desktop notification that stays in the notification centre (`notification_for` in `engine.rs`) |
| `room.accepted` | `room` | `name` | not shown |
| `scene.started` | `scene` | `name`, `title` | not shown |
| `scene.done` | `scene` | `name`, `title`, `announce`, `failed` | title when `announce`; "Scene failed, <title>" when `failed` > 0 |
| `palette.toggle` | `keymap` | none | opens or closes the palette (handled in `main.rs`, no card) |

### Continuity (device roster and room transfer)

- **Roster:** `lab-roster` (`home/lab/roster.nix`, `home/scripts/lab-roster.py`) reads `tailscale status --json` every 15 s, keeps only nodes owned by your own tailnet user, and names them from `lab.roster.devices` (keyed by the tailscale dns label). It publishes `roster.changed` on change and every 4 minutes, and `roster.device` when a device goes online or offline.
- **Transport is Taildrop, on purpose.** `room send NAME` runs `tailscale file cp` to the peer (`lab.rooms.peer`, default the handoff peer). Tailscale authenticates the transfer between your own devices and labd opens no listener, so there is no new network surface. Do not replace this with a custom port or ssh without a written reason.
- **Items that wait for you get a notification too.** The island is a few seconds long and easy to miss, so `notification_for` in `src/engine.rs` posts a notification for events that need a later action (today only `room.received`). The shell decides this, publishers never call `notify-send`.
- **Receiving:** `lab-inbox` (`home/scripts/lab-inbox.py`, started from `home/rooms.nix`) runs `tailscale file get --wait` into `~/.local/state/rooms/inbox-raw`, validates each file (JSON, at most 256 KB, safe name, a non-empty `windows` list), moves valid ones to `~/.local/state/rooms/inbox` and publishes `room.received`. It needs tailscale's operator to be your user (`--operator=justkowal`; set on the desktop, and via `extraSetFlags` on the laptop). Nothing opens automatically.
- **Accepting is explicit.** Inbox rooms appear first in the palette ("<name> from <device>"). Enter runs `room take NAME`, which accepts the room and opens it. Accepting rewrites it with `sanitize_foreign` in `room.py`: terminals keep only their cwd, browsers keep nothing else, other windows may relaunch only an installed desktop application by program name with no arguments, and anything else is dropped. A received room can never carry its own command line.
- **Send:** typing "send" in the palette lists "Send <room> to <peer>" for each saved room (rank 2, hidden from the default list). Rooms saved by `leave` (`last`) are sendable too.
- `lab doctor` has a "continuity services" check that fails with the reason when `lab-roster` or `lab-inbox` is not running.

## 12. The help window and keeping the terminal optional

- **Help app** (`pkgs/labd/src/help.rs`, `SUPER + /`, or the palette entries "Features overview" and "Health check"): a floating window with three pages. *Keybinds* reads `hyprctl binds -j` live, so it can never drift from what the compositor really has, and labels each bind from `keymap.json` first, otherwise from `describe()` (readable names for the common dispatchers and commands, grouped). Binds inside a mode say which key enters it. *Features* shows `~/.config/lab/help.json`, generated by `home/lab/help.nix` (`lab.help.features`; shortcuts are looked up from the keymap by label, never typed by hand). *Health* runs `lab doctor` and shows plain names with OK or FIX chips. It opens on a page with `lab publish help.toggle --payload '{"page":"health"}'` (`binds`, `features`, `health`); asking for the page that is showing closes it. It is the only toplevel window labd opens, so the float/size/center rule matches the app id `lab.justkowal.Labd`.
- **The rule of thumb:** a basic action must be reachable without typing a command. Anything a user would plausibly do (focus for N minutes, pomodoro, keep awake, clipboard history, tablet display, snapshots, saving or sending a room, system update, power actions) is a palette entry. Add formerly CLI-only actions to `home/lab/actions.nix` (`lab.palette.entries`); gate host-specific ones (`laptop`, `config.lab.handoff.enable`) so the palette never lists a command that is not installed. Check `command -v <tool>` on both machines first.
- **Known gaps:** focus mode needs the rpi4 hub deployed with `hosts/rpi4/focus.nix` and the webhook hooks (`/hooks/focus-on`, `focus-off`, `focus-status`). While the hub runs an older system those answer 404 and `focus` says so in the island (`focus.failed`) instead of failing silently; deploy `nixos-rpi4` to fix it. `lab.handoff.enable` is not turned on for any host, so `home-lan` (automatic handoff) does not run; the "Handoff: suspend or resume" entry only appears once it is enabled.
