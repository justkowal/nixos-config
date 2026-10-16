#!/usr/bin/env bash
# monitor-ctl: lid/dock handling, display modes, new-monitor arrangement and hotplug sync
# a failed hyprctl call must not kill the long-running listener
set +e -uo pipefail

INTERNAL="eDP-1"
INTERNAL_RULE="$INTERNAL,preferred,0x0,1"
FALLBACK_WALL="/home/justkowal/Pictures/wallpaper.png"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
SAVED_RULES="$HYPR_DIR/monitors.conf"
PRIMARY_CONF="$HYPR_DIR/primary.conf"
WAYBAR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"
PROFILE="/sys/firmware/acpi/platform_profile"

has_internal() { compgen -G "/sys/class/drm/card*-$INTERNAL" >/dev/null; }

# headless outputs are tablet streams and mirrors aren't separate screens
externals() {
  hyprctl monitors -j | jq -r --arg i "$INTERNAL" \
    '.[] | select(.name != $i and (.name | startswith("HEADLESS") | not) and .mirrorOf == "none") | .name'
}

first_external() { externals | head -n1; }

internal_enabled() { hyprctl monitors -j | jq -e --arg i "$INTERNAL" 'any(.[]; .name == $i)' >/dev/null; }

enable_internal() { hyprctl keyword monitor "$INTERNAL_RULE" >/dev/null; }

disable_internal() { hyprctl keyword monitor "$INTERNAL,disable" >/dev/null; }

lid_closed() { grep -qs closed /proc/acpi/button/lid/*/state; }

on_ac() { grep -qs 1 /sys/class/power_supply/AC*/online; }

caffeinated() { pgrep -f "systemd-inhibit --what=sleep:handle-lid-switch" >/dev/null; }

current_wallpaper() {
  local skip="${1:-}" path
  path=$(awww query 2>/dev/null | grep -v -- "$skip: " | grep -o 'image: .*' | head -n1 | cut -d' ' -f2-)
  echo "${path:-$FALLBACK_WALL}"
}

# 1-5 follow the external screen, 6-10 stay on the panel
pin_workspaces() {
  local ext ws
  has_internal || return 0
  ext=$(first_external)
  [ -n "$ext" ] || return 0
  for ws in 1 2 3 4 5; do
    hyprctl keyword workspace "$ws,monitor:$ext" >/dev/null
    hyprctl dispatch moveworkspacetomonitor "$ws" "$ext" >/dev/null
  done
  if internal_enabled; then
    for ws in 6 7 8 9 10; do
      hyprctl keyword workspace "$ws,monitor:$INTERNAL" >/dev/null
      hyprctl dispatch moveworkspacetomonitor "$ws" "$INTERNAL" >/dev/null
    done
  fi
}

# primary = where the full waybar and the hyprlock prompt go
sync_primary() {
  has_internal || return 0
  local primary layout target
  primary=$(first_external)
  if [ -n "$primary" ]; then layout="docked.json"; else primary="$INTERNAL"; layout="config"; fi

  printf "\$lock_monitor = %s\n" "$primary" > "$PRIMARY_CONF"

  target=$(readlink "$WAYBAR_DIR/active.json" 2>/dev/null)
  if [ "$target" != "$layout" ]; then
    ln -sfn "$layout" "$WAYBAR_DIR/active.json"
    systemctl --user reload waybar 2>/dev/null || systemctl --user restart waybar
  fi
}

# tlp pins low-power on every power event, so wait for it before overriding
sync_power_profile() {
  has_internal || return 0
  [ -w "$PROFILE" ] || return 0
  [ -f /run/ultra-power-mode.active ] && return 0
  (
    sleep 3
    if [ -n "$(first_external)" ] && on_ac; then
      echo balanced > "$PROFILE"
    else
      echo low-power > "$PROFILE"
    fi
  ) &
}

sync_all() {
  pin_workspaces
  sync_primary
  sync_power_profile
}

# offer a placement the first time an unknown monitor shows up, then remember it by edid description
arrange_new() {
  local name="$1" desc choice pos rule
  has_internal || return 0
  desc=$(hyprctl monitors -j | jq -r --arg n "$name" '.[] | select(.name == $n) | .description')
  [ -n "$desc" ] || return 0
  touch "$SAVED_RULES"
  grep -qF "desc:$desc," "$SAVED_RULES" && return 0

  choice=$(notify-send -i video-display -t 0 \
    -A up="Above" -A left="Left" -A right="Right" -A mirror="Mirror" \
    "New display: $name" "$desc")
  case "$choice" in
    up) pos="preferred,auto-center-up,1,vrr,2" ;;
    left) pos="preferred,auto-center-left,1,vrr,2" ;;
    right) pos="preferred,auto-center-right,1,vrr,2" ;;
    mirror) pos="preferred,auto,1,mirror,$INTERNAL" ;;
    *) return 0 ;;
  esac
  rule="desc:$desc,$pos"
  echo "monitor=$rule" >> "$SAVED_RULES"
  hyprctl keyword monitor "$rule" >/dev/null
  sleep 0.5
  sync_all
}

set_mode() {
  local ext
  case "$1" in
    extend)
      hyprctl reload >/dev/null
      sleep 0.5
      if lid_closed && [ -n "$(externals)" ]; then disable_internal; fi
      ;;
    external)
      [ -n "$(externals)" ] || { notify-send -i video-display "Display" "No external display connected"; return 1; }
      disable_internal
      ;;
    mirror)
      internal_enabled || enable_internal
      for ext in $(externals); do
        hyprctl keyword monitor "$ext,preferred,auto,1,mirror,$INTERNAL" >/dev/null
      done
      ;;
    laptop)
      internal_enabled || enable_internal
      for ext in $(externals); do
        hyprctl keyword monitor "$ext,disable" >/dev/null
      done
      ;;
  esac
  sleep 0.5
  sync_all
}

mode_menu() {
  local choice
  choice=$(printf '%s\n' \
    "󰍺  Extend" \
    "󰍹  External only" \
    "󰍸  Mirror" \
    "󰌢  Laptop only" | rofi -dmenu -i -p "Display mode")
  case "$choice" in
    *Extend) set_mode extend ;;
    *External*) set_mode external ;;
    *Mirror) set_mode mirror ;;
    *Laptop*) set_mode laptop ;;
  esac
}

case "${1:-}" in
  lid-close)
    if [ -n "$(externals)" ]; then
      disable_internal
      sync_all
    else
      loginctl lock-session
      sleep 0.5
      hyprctl dispatch dpms off
    fi
    ;;
  lid-open)
    internal_enabled || enable_internal
    hyprctl dispatch dpms on
    sleep 0.5
    sync_all
    ;;
  mode)
    if [ -n "${2:-}" ]; then set_mode "$2"; else mode_menu; fi
    ;;
  listen)
    # booted docked with the lid shut: hyprland enables the panel anyway
    if has_internal && lid_closed && [ -n "$(externals)" ]; then
      disable_internal
    fi
    sync_all
    socat -U - "UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" | while IFS= read -r line; do
      case "$line" in
        monitoraddedv2\>\>*)
          name=$(echo "${line#*>>}" | cut -d, -f2)
          case "$name" in HEADLESS*) continue ;; esac
          # awww only paints outputs it has seen before, new ones stay black
          sleep 0.5
          awww img -o "$name" "$(current_wallpaper "$name")" --transition-type none || true
          [ "$name" = "$INTERNAL" ] && continue
          if has_internal && lid_closed && internal_enabled; then
            disable_internal
          fi
          sync_all
          arrange_new "$name" &
          ;;
        monitorremoved\>\>*)
          has_internal || continue
          [ "${line#*>>}" = "$INTERNAL" ] && continue
          [ -n "$(externals)" ] && { sync_all; continue; }
          # undocked with the lid shut: never sit at zero screens, and don't drain the battery in a bag
          internal_enabled || enable_internal
          sync_all
          if lid_closed && ! on_ac && ! caffeinated; then
            sleep 5
            # logind may have suspended already; after resume the lid is open and this is skipped
            if lid_closed && ! on_ac; then
              loginctl lock-session
              systemctl suspend
            fi
          fi
          ;;
      esac
    done
    ;;
  *)
    echo "Usage: monitor-ctl [lid-close|lid-open|mode [extend|external|mirror|laptop]|listen]"
    exit 1
    ;;
esac
