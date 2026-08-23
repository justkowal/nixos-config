#!/usr/bin/env bash
# Monitor brightness control via DDC/CI with notification OSD
case "$1" in
  up) ddcutil setvcp 10 + 5 ;;
  down) ddcutil setvcp 10 - 5 ;;
esac

BRIGHT=$(ddcutil getvcp 10 2>/dev/null | grep -oP 'current value =\s*\K\d+' || echo "50")
notify-send -h string:x-canonical-private-synchronous:osd -h int:value:"$BRIGHT" -i display-brightness "Monitor Brightness" "$BRIGHT%"
