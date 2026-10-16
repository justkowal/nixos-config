#!/usr/bin/env bash
# focus: fleet-wide focus mode. State lives on the rpi4 (webhook hooks focus-on/off/status).
set -euo pipefail

HOOKS="${FOCUS_HOOKS:-http://nixos-rpi4.lab:9100/hooks}"
RUN="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
CACHE="$RUN/focus-state.json"
MARKER="$RUN/focus-pomodoro"
CACHE_TTL=20

have() { command -v "$1" >/dev/null 2>&1; }

state() {
  local age=$CACHE_TTL
  [ -f "$CACHE" ] && age=$(( $(date +%s) - $(stat -c %Y "$CACHE") ))
  if [ "$age" -ge "$CACHE_TTL" ]; then
    if curl -fsS -m 3 "$HOOKS/focus-status" > "$CACHE.tmp" 2>/dev/null && jq -e . "$CACHE.tmp" >/dev/null 2>&1; then
      mv "$CACHE.tmp" "$CACHE"
    else
      rm -f "$CACHE.tmp"
      # rpi4 unreachable: keep the last known state rather than flapping
      touch "$CACHE" 2>/dev/null || true
    fi
  fi
  cat "$CACHE" 2>/dev/null || echo '{"active":false,"until":null}'
}

is_active() {
  state | jq -e --argjson now "$(date +%s)" '.active == true and (.until == null or .until > $now)' >/dev/null 2>&1
}

remaining_min() {
  state | jq -r --argjson now "$(date +%s)" 'if .until then ((.until - $now) / 60 | ceil) else "" end'
}

openrgb_profile() {
  [ -n "${FOCUS_OPENRGB:-}" ] || return 0
  python3 - "$1" <<'EOF' >/dev/null 2>&1 || true
import sys
from openrgb import OpenRGBClient
OpenRGBClient(name="focus").load_profile(sys.argv[1])
EOF
}

focus_on() {
  local minutes="${1:-25}"
  curl -fsS -m 5 -X POST "$HOOKS/focus-on?minutes=$minutes" >/dev/null
  rm -f "$CACHE"
  touch "$MARKER"
  if have pomodoro; then
    pomodoro reset
    pomodoro toggle
  fi
  have caffeine && caffeine on >/dev/null
  openrgb_profile "${FOCUS_OPENRGB_ON:-focus}"
  notify-send -a Focus -i timer-symbolic "Focus on" "$minutes min, distractions blocked fleet-wide"
}

focus_off() {
  curl -fsS -m 5 -X POST "$HOOKS/focus-off" >/dev/null || true
  rm -f "$CACHE"
  if [ -f "$MARKER" ]; then
    rm -f "$MARKER"
    have caffeine && caffeine off >/dev/null
  fi
  openrgb_profile "${FOCUS_OPENRGB_OFF:-default}"
  notify-send -a Focus -i timer-symbolic "Focus off" ""
}

waybar() {
  local min
  if is_active; then
    min=$(remaining_min)
    jq -nc --arg m "$min" '{text: ("󰓾 " + $m + "m"), class: "active", tooltip: "Focus on, \($m) min left\nClick to end"}'
  else
    # focus ended elsewhere (rpi4 expiry or the other machine): undo the local side effects once
    if [ -f "$MARKER" ]; then
      rm -f "$MARKER"
      have caffeine && caffeine off >/dev/null
      openrgb_profile "${FOCUS_OPENRGB_OFF:-default}"
    fi
    jq -nc '{text: "󰓾", class: "inactive", tooltip: "Focus off\nClick for 25 min of focus"}'
  fi
}

# exit 0 = show the notification. urgent (priority >= 4) always gets through.
gate() {
  local priority="${1:-3}"
  [[ "$priority" =~ ^[0-9]+$ ]] || priority=3
  [ "$priority" -ge 4 ] && return 0
  ! is_active
}

case "${1:-status}" in
  on) focus_on "${2:-25}" ;;
  off) focus_off ;;
  toggle) if is_active; then focus_off; else focus_on "${2:-25}"; fi ;;
  status) state ;;
  waybar) waybar ;;
  gate) gate "${2:-3}" ;;
  *) echo "usage: focus {on [minutes]|off|toggle|status|waybar|gate <priority>}" >&2; exit 1 ;;
esac
