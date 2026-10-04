#!/usr/bin/env bash
# Volume & Microphone control with SwayOSD (avoids D-Bus notification bus spam) and ThinkPad hardware LED sync

if [ "$1" = "mic-mute" ]; then
  wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
  MIC_MUTED=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ | grep -i MUTED || true)
  if [ -n "$MIC_MUTED" ]; then
    [ -w /sys/class/leds/platform::micmute/brightness ] && echo 1 > /sys/class/leds/platform::micmute/brightness 2>/dev/null || true
  else
    [ -w /sys/class/leds/platform::micmute/brightness ] && echo 0 > /sys/class/leds/platform::micmute/brightness 2>/dev/null || true
  fi
  swayosd-client --input-volume mute-toggle 2>/dev/null || true
  exit 0
fi

case "$1" in
  up)
    wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+
    swayosd-client --output-volume raise 2>/dev/null || true
    ;;
  down)
    wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
    swayosd-client --output-volume lower 2>/dev/null || true
    ;;
  mute)
    wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
    swayosd-client --output-volume mute-toggle 2>/dev/null || true
    ;;
esac

MUTED=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -i MUTED || true)
if [ -n "$MUTED" ]; then
  [ -w /sys/class/leds/platform::mute/brightness ] && echo 1 > /sys/class/leds/platform::mute/brightness 2>/dev/null || true
else
  [ -w /sys/class/leds/platform::mute/brightness ] && echo 0 > /sys/class/leds/platform::mute/brightness 2>/dev/null || true
fi

