#!/usr/bin/env bash
# Volume & microphone control. Feedback goes to the island through the lab bus;
# swayosd is only the fallback while labd is down. Also syncs the ThinkPad mute LEDs.

# publish EVENT PAYLOAD || fallback: strict so a down bus triggers the swayosd fallback
publish() {
  lab publish "$1" --source volume --strict --ttl 5 --payload "$2" 2>/dev/null
}

if [ "$1" = "mic-mute" ]; then
  wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
  MIC_MUTED=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ | grep -i MUTED || true)
  if [ -n "$MIC_MUTED" ]; then
    [ -w /sys/class/leds/platform::micmute/brightness ] && echo 1 > /sys/class/leds/platform::micmute/brightness 2>/dev/null || true
    publish mic.changed '{"muted":true}' ||
      swayosd-client --custom-icon microphone-disabled --custom-message "Microphone Muted" 2>/dev/null || true
  else
    [ -w /sys/class/leds/platform::micmute/brightness ] && echo 0 > /sys/class/leds/platform::micmute/brightness 2>/dev/null || true
    publish mic.changed '{"muted":false}' ||
      swayosd-client --custom-icon microphone-sensitivity-high --custom-message "Microphone Active" 2>/dev/null || true
  fi
  exit 0
fi

case "$1" in
  up) wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+ ;;
  down) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
  mute) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
esac

LINE=$(wpctl get-volume @DEFAULT_AUDIO_SINK@)
VOL=$(awk '{printf "%d", $2 * 100 + 0.5}' <<< "$LINE")
if grep -qi muted <<< "$LINE"; then
  MUTED=true
  [ -w /sys/class/leds/platform::mute/brightness ] && echo 1 > /sys/class/leds/platform::mute/brightness 2>/dev/null || true
else
  MUTED=false
  [ -w /sys/class/leds/platform::mute/brightness ] && echo 0 > /sys/class/leds/platform::mute/brightness 2>/dev/null || true
fi

publish volume.changed "{\"value\":$VOL,\"muted\":$MUTED}" ||
  swayosd-client --custom-progress "$(awk -v v="$VOL" 'BEGIN {print (v > 100 ? 1 : v / 100)}')" \
    --custom-icon audio-volume-high --custom-message "Volume $VOL%" 2>/dev/null || true
