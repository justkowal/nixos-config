#!/usr/bin/env bash
# Brightness for the focused (or named) monitor: backlight for the panel, DDC/CI for externals
# usage: brightness-osd up|down|get [MONITOR] | set PCT [MONITOR]

ACTION="${1:-}"
if [ "$ACTION" = "set" ]; then
  VALUE="${2:-}"
  TARGET="${3:-}"
else
  TARGET="${2:-}"
fi

MONITORS=$(hyprctl monitors -j 2>/dev/null || echo '[]')
[ -n "$TARGET" ] || TARGET=$(echo "$MONITORS" | jq -r '.[] | select(.focused) | .name')

HAS_BACKLIGHT=0
if command -v brightnessctl >/dev/null 2>&1 && [ -n "$(ls -A /sys/class/backlight 2>/dev/null)" ]; then
  HAS_BACKLIGHT=1
fi

osd() {
  local pct="$1"
  [ "$ACTION" = "get" ] && return 0
  swayosd-client --monitor "$TARGET" --custom-progress "$(awk -v b="$pct" 'BEGIN {print b / 100}')" \
    --custom-icon display-brightness --custom-message "Brightness $pct%" 2>/dev/null || true
}

if [ "$HAS_BACKLIGHT" -eq 1 ] && { [ -z "$TARGET" ] || [[ "$TARGET" == eDP-* ]]; }; then
  case "$ACTION" in
    up) brightnessctl set 5%+ -q ;;
    down) brightnessctl set 5%- -q ;;
    set) brightnessctl set "$VALUE%" -q ;;
  esac
  PCT=$(( $(brightnessctl g) * 100 / $(brightnessctl m) ))
else
  # match the ddc bus by edid serial, so the right screen changes with several plugged in
  SERIAL=$(echo "$MONITORS" | jq -r --arg n "$TARGET" '.[] | select(.name == $n) | .serial')
  MODEL=$(echo "$MONITORS" | jq -r --arg n "$TARGET" '.[] | select(.name == $n) | .model')
  DDC=(ddcutil --sleep-multiplier 0.5)
  if [ -n "$SERIAL" ] && [ "$SERIAL" != "null" ]; then
    DDC+=(--sn "$SERIAL")
  elif [ -n "$MODEL" ] && [ "$MODEL" != "null" ]; then
    DDC+=(--model "$MODEL")
  fi
  case "$ACTION" in
    up) "${DDC[@]}" setvcp 10 + 5 2>/dev/null ;;
    down) "${DDC[@]}" setvcp 10 - 5 2>/dev/null ;;
    set) "${DDC[@]}" setvcp 10 "$VALUE" --noverify 2>/dev/null ;;
  esac
  PCT=$("${DDC[@]}" --brief getvcp 10 2>/dev/null | awk '/^VCP 10/ {print $4; exit}')
  if [ -z "$PCT" ]; then
    [ "$ACTION" = "get" ] && exit 1
    PCT=50
  fi
fi

if [ "$ACTION" = "get" ]; then
  echo "$PCT"
else
  osd "$PCT"
fi
