#!/usr/bin/env bash
# caffeine.sh: System Sleep & Lid Suspend Inhibitor
# Inhibits sleep, idle timeout, and lid-close suspend while preserving automatic session locking.
# Strictly SF / Nerd Font iconography (no emojis).

set -euo pipefail

RUNTIME_DIR="/run/user/$(id -u)"
PID_FILE="$RUNTIME_DIR/caffeine.pid"
STATE_FILE="$RUNTIME_DIR/caffeine.active"

is_active() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  # Cleanup stale files if process died
  rm -f "$PID_FILE" "$STATE_FILE" 2>/dev/null || true
  return 1
}

enable_caffeine() {
  if is_active; then
    echo "Caffeine mode is already active."
    return 0
  fi

  # Launch systemd-inhibit in background
  systemd-inhibit \
    --what=sleep:handle-lid-switch:idle \
    --who="Caffeine" \
    --why="Caffeine mode prevents system suspend on idle and lid close" \
    --mode=block \
    sleep infinity >/dev/null 2>&1 &

  local in_pid=$!
  echo "$in_pid" > "$PID_FILE"
  touch "$STATE_FILE"

  if command -v swayosd-client >/dev/null 2>&1; then
    swayosd-client --custom-icon preferences-system-time --custom-message "Caffeine: Active" 2>/dev/null || true
  fi
  echo "✓ Caffeine mode activated (PID: $in_pid)"
}

disable_caffeine() {
  if ! is_active; then
    echo "Caffeine mode is not active."
    return 0
  fi

  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    # Also kill any orphan sleep infinity under our user
    pkill -f "systemd-inhibit --what=sleep:handle-lid-switch:idle" 2>/dev/null || true
  fi
  rm -f "$PID_FILE" "$STATE_FILE" 2>/dev/null || true

  if command -v swayosd-client >/dev/null 2>&1; then
    swayosd-client --custom-icon preferences-system-time --custom-message "Caffeine: Off" 2>/dev/null || true
  fi
  echo "✓ Caffeine mode disabled"
}

toggle_caffeine() {
  if is_active; then
    disable_caffeine
  else
    enable_caffeine
  fi
}

show_status() {
  if is_active; then
    echo "active"
  else
    echo "inactive"
  fi
}

show_waybar() {
  if is_active; then
    printf '{"text":"󰅶","tooltip":"Caffeine Mode: ACTIVE\\nSleep & Lid Suspend Inhibited\\nLeft-click: Toggle Off","class":"active","alt":"active"}\n'
  else
    printf '{"text":"󰒲","tooltip":"Caffeine Mode: INACTIVE\\nNormal Sleep & Lid Suspend\\nLeft-click: Toggle On","class":"inactive","alt":"inactive"}\n'
  fi
}

case "${1:-status}" in
  on|enable|start) enable_caffeine ;;
  off|disable|stop) disable_caffeine ;;
  toggle) toggle_caffeine ;;
  status) show_status ;;
  waybar) show_waybar ;;
  *)
    echo "Usage: caffeine {on|off|toggle|status|waybar}"
    exit 1
    ;;
esac
