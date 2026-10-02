#!/usr/bin/env bash
# Brightness control for internal laptop display (brightnessctl) and external monitors (ddcutil)

# Check if an internal backlight device exists (e.g. amdgpu_bl1)
HAS_BACKLIGHT=0
if [ -d /sys/class/backlight ] && [ -n "$(ls -A /sys/class/backlight 2>/dev/null)" ]; then
  HAS_BACKLIGHT=1
fi

if [ "$HAS_BACKLIGHT" -eq 1 ] && command -v brightnessctl >/dev/null 2>&1; then
  case "$1" in
    up) brightnessctl set 5%+ -q ;;
    down) brightnessctl set 5%- -q ;;
  esac
  BRIGHT=$(brightnessctl -m | head -n 1 | cut -d',' -f4 | tr -d '%')
  notify-send -h string:x-canonical-private-synchronous:osd -h int:value:"$BRIGHT" -i display-brightness "Brightness" "$BRIGHT%"
else
  case "$1" in
    up) ddcutil setvcp 10 + 5 2>/dev/null ;;
    down) ddcutil setvcp 10 - 5 2>/dev/null ;;
  esac
  BRIGHT=$(ddcutil getvcp 10 2>/dev/null | grep -oP 'current value =\s*\K\d+' || echo "50")
  notify-send -h string:x-canonical-private-synchronous:osd -h int:value:"$BRIGHT" -i display-brightness "Monitor Brightness" "$BRIGHT%"
fi
