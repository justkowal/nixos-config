#!/usr/bin/env bash
# Brightness control with SwayOSD (avoids D-Bus notification bus spam)

HAS_BACKLIGHT=0
if [ -d /sys/class/backlight ] && [ -n "$(ls -A /sys/class/backlight 2>/dev/null)" ]; then
  HAS_BACKLIGHT=1
fi

if [ "$HAS_BACKLIGHT" -eq 1 ] && command -v brightnessctl >/dev/null 2>&1; then
  case "$1" in
    up)
      brightnessctl set 5%+ -q
      swayosd-client --brightness raise 2>/dev/null || true
      ;;
    down)
      brightnessctl set 5%- -q
      swayosd-client --brightness lower 2>/dev/null || true
      ;;
  esac
else
  case "$1" in
    up) ddcutil setvcp 10 + 5 2>/dev/null ;;
    down) ddcutil setvcp 10 - 5 2>/dev/null ;;
  esac
  BRIGHT=$(ddcutil getvcp 10 2>/dev/null | grep -oP 'current value =\s*\K\d+' || echo "50")
  PROGRESS=$(awk -v b="$BRIGHT" 'BEGIN {print b / 100}')
  swayosd-client --custom-progress "$PROGRESS" --custom-icon display-brightness --custom-message "Brightness $BRIGHT%" 2>/dev/null || true
fi

