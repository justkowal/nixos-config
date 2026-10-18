#!/usr/bin/env bash
# Visual regression for the island: draws each event in a headless compositor and compares a crop of the
# top of the screen with a golden image. Run `nix run .#lab-visual`, add `-- --update` to accept new looks.
# Needs LAB_VISUAL_FONTS (set by the flake) so the pictures do not depend on this machine's fonts.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
golden="${LAB_VISUAL_GOLDEN:-$here/visual/golden}"
update=0
[ "${1:-}" = "--update" ] && update=1
tolerance="${LAB_VISUAL_TOLERANCE:-200}"

work="$(mktemp -d)"
export XDG_RUNTIME_DIR="$work/rt" XDG_CONFIG_HOME="$work/cfg"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME"
chmod 700 "$XDG_RUNTIME_DIR"
export WLR_BACKENDS=headless WLR_RENDERER=pixman LIBGL_ALWAYS_SOFTWARE=1 GSK_RENDERER=cairo WAYLAND_DISPLAY=wayland-0
export FONTCONFIG_FILE="${LAB_VISUAL_FONTS:?run this through nix run .#lab-visual}"
unset HYPRLAND_INSTANCE_SIGNATURE

pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

dbus_conf="$(dirname "$(dirname "$(readlink -f "$(command -v dbus-daemon)")")")/share/dbus-1/session.conf"
dbus-daemon --config-file="$dbus_conf" --nofork --print-address=3 3>"$work/addr" 2>/dev/null &
pids+=($!)
sleep 1
DBUS_SESSION_BUS_ADDRESS="$(cat "$work/addr")"
export DBUS_SESSION_BUS_ADDRESS
labwc >/dev/null 2>&1 &
pids+=($!)
sleep 3
swaybg -c 121212 >/dev/null 2>&1 &
pids+=($!)
labd >"$work/labd.log" 2>&1 &
pids+=($!)
sleep 4

# name, event, payload
cases=(
  "volume|volume.changed|{\"value\": 42, \"muted\": false}"
  "muted|volume.changed|{\"value\": 42, \"muted\": true}"
  "focus-on|focus.on|{\"minutes\": \"25\"}"
  "room-saved|room.saved|{\"name\": \"nixos-config\", \"windows\": 4}"
  "auth-waiting|auth.waiting|{\"app\": \"sudo\", \"host\": \"laptop\"}"
  "clipboard|clipboard.received|{\"host\": \"Desktop\", \"chars\": 12}"
  "wake-up|wake.progress|{\"title\": \"Desktop\", \"state\": \"up\"}"
  "wake-online|wake.progress|{\"title\": \"Desktop\", \"state\": \"online\"}"
  "theme|theme.changed|{\"title\": \"Soft\"}"
)

failed=0
mkdir -p "$golden"
for c in "${cases[@]}"; do
  IFS='|' read -r name event payload <<<"$c"
  lab-publish "$event" --source visual --priority high --ttl 400 --payload "$payload"
  sleep 0.8
  grim -g "340,0 600x80" "$work/$name.png"
  if [ "$update" = 1 ] || [ ! -f "$golden/$name.png" ]; then
    cp "$work/$name.png" "$golden/$name.png"
    echo "wrote $name"
    continue
  fi
  diff_px="$(compare -metric AE -fuzz 6% "$golden/$name.png" "$work/$name.png" null: 2>&1 || true)"
  diff_px="${diff_px%% *}"
  if [ "${diff_px:-999999}" -le "$tolerance" ]; then
    echo "ok      $name ($diff_px px differ)"
  else
    echo "FAILED  $name ($diff_px px differ, tolerance $tolerance)"
    cp "$work/$name.png" "$golden/$name.actual.png"
    failed=1
  fi
done
exit "$failed"
