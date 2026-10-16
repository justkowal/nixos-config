#!/usr/bin/env bash
# Volume & Microphone control with SwayOSD (avoids D-Bus notification bus spam) and ThinkPad hardware LED sync

if [ "$1" = "mic-mute" ]; then
  wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
  MIC_MUTED=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ | grep -i MUTED || true)
  if [ -n "$MIC_MUTED" ]; then
    [ -w /sys/class/leds/platform::micmute/brightness ] && echo 1 > /sys/class/leds/platform::micmute/brightness 2>/dev/null || true
    swayosd-client --custom-icon microphone-disabled --custom-message "Microphone Muted" 2>/dev/null || true
  else
    [ -w /sys/class/leds/platform::micmute/brightness ] && echo 0 > /sys/class/leds/platform::micmute/brightness 2>/dev/null || true
    swayosd-client --custom-icon microphone-sensitivity-high --custom-message "Microphone Active" 2>/dev/null || true
  fi
  exit 0
fi

case "$1" in
  up)
    if ! swayosd-client --output-volume raise --max-volume 150 2>/dev/null; then
      wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+
    fi
    ;;
  down)
    if ! swayosd-client --output-volume lower --max-volume 150 2>/dev/null; then
      wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
    fi
    ;;
  mute)
    if ! swayosd-client --output-volume mute-toggle 2>/dev/null; then
      wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
    fi
    ;;
esac

MUTED=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -i MUTED || true)
if [ -n "$MUTED" ]; then
  [ -w /sys/class/leds/platform::mute/brightness ] && echo 1 > /sys/class/leds/platform::mute/brightness 2>/dev/null || true
else
  [ -w /sys/class/leds/platform::mute/brightness ] && echo 0 > /sys/class/leds/platform::mute/brightness 2>/dev/null || true
fi


