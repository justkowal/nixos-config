#!/usr/bin/env bash
# Volume & Microphone control with notification OSD and ThinkPad hardware LED sync

if [ "$1" = "mic-mute" ]; then
  wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
  MIC_MUTED=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ | grep -i MUTED || true)
  if [ -n "$MIC_MUTED" ]; then
    [ -w /sys/class/leds/platform::micmute/brightness ] && echo 1 > /sys/class/leds/platform::micmute/brightness 2>/dev/null || true
    notify-send -h string:x-canonical-private-synchronous:osd -h int:value:0 -i microphone-sensitivity-muted "Microphone" "Muted"
  else
    [ -w /sys/class/leds/platform::micmute/brightness ] && echo 0 > /sys/class/leds/platform::micmute/brightness 2>/dev/null || true
    notify-send -h string:x-canonical-private-synchronous:osd -h int:value:100 -i microphone-sensitivity-high "Microphone" "Active (Unmuted)"
  fi
  exit 0
fi

case "$1" in
  up) wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+ ;;
  down) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
  mute) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
esac

VOL=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2 * 100)}')
MUTED=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -i MUTED || true)

if [ -n "$MUTED" ]; then
  [ -w /sys/class/leds/platform::mute/brightness ] && echo 1 > /sys/class/leds/platform::mute/brightness 2>/dev/null || true
  notify-send -h string:x-canonical-private-synchronous:osd -h int:value:0 -i audio-volume-muted "Volume" "Muted (0%)"
else
  [ -w /sys/class/leds/platform::mute/brightness ] && echo 0 > /sys/class/leds/platform::mute/brightness 2>/dev/null || true
  notify-send -h string:x-canonical-private-synchronous:osd -h int:value:"$VOL" -i audio-volume-high "Volume" "$VOL%"
fi
