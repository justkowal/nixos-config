#!/usr/bin/env bash
# Volume control with notification OSD
case "$1" in
  up) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ ;;
  down) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
  mute) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
esac

VOL=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2 * 100)}')
MUTED=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -i MUTED)

if [ -n "$MUTED" ]; then
  notify-send -h string:x-canonical-private-synchronous:osd -h int:value:0 -i audio-volume-muted "Volume" "Muted (0%)"
else
  notify-send -h string:x-canonical-private-synchronous:osd -h int:value:"$VOL" -i audio-volume-high "Volume" "$VOL%"
fi
