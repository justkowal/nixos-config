#!/bin/bash
# Pomodoro timer for Waybar (JSON output with CSS classes)
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/waybar-pomodoro"

init_state() {
  cat <<EOF > "$STATE_FILE"
status=idle
type=work
target_time=0
remaining_time=1500
cycles=0
EOF
}

load_state() {
  if [ ! -f "$STATE_FILE" ]; then init_state; fi
  status=$(grep "^status=" "$STATE_FILE" | cut -d= -f2)
  type=$(grep "^type=" "$STATE_FILE" | cut -d= -f2)
  target_time=$(grep "^target_time=" "$STATE_FILE" | cut -d= -f2)
  remaining_time=$(grep "^remaining_time=" "$STATE_FILE" | cut -d= -f2)
  cycles=$(grep "^cycles=" "$STATE_FILE" | cut -d= -f2)
  status=${status:-idle}
  type=${type:-work}
  target_time=${target_time:-0}
  remaining_time=${remaining_time:-1500}
  cycles=${cycles:-0}
}

save_state() {
  cat <<EOF > "$STATE_FILE"
status=$status
type=$type
target_time=$target_time
remaining_time=$remaining_time
cycles=$cycles
EOF
}

toggle() {
  load_state
  current_time=$(date +%s)
  if [ "$status" = "idle" ]; then
    status="running"
    if [ "$type" = "work" ]; then
      remaining_time=1500
    else
      if [ $((cycles % 4)) -eq 0 ] && [ "$cycles" -ne 0 ]; then
        remaining_time=900
      else
        remaining_time=300
      fi
    fi
    target_time=$((current_time + remaining_time))
  elif [ "$status" = "running" ]; then
    status="paused"
    remaining_time=$((target_time - current_time))
    if [ "$remaining_time" -lt 0 ]; then remaining_time=0; fi
    target_time=0
  elif [ "$status" = "paused" ]; then
    status="running"
    target_time=$((current_time + remaining_time))
  fi
  save_state
}

reset() { init_state; }

skip() {
  load_state
  if [ "$type" = "work" ]; then
    type="break"
    cycles=$((cycles + 1))
    if [ $((cycles % 4)) -eq 0 ]; then remaining_time=900; else remaining_time=300; fi
  else
    type="work"
    remaining_time=1500
  fi
  status="paused"
  target_time=0
  save_state
}

status() {
  load_state
  current_time=$(date +%s)

  if [ "$status" = "running" ]; then
    remaining=$((target_time - current_time))
    if [ "$remaining" -le 0 ]; then
      if [ "$type" = "work" ]; then
        cycles=$((cycles + 1))
        type="break"
        if [ $((cycles % 4)) -eq 0 ]; then
          remaining_time=900; msg="Time for a long break (15 mins)!"
        else
          remaining_time=300; msg="Time for a short break (5 mins)!"
        fi
        notify-send -u critical -i timer-symbolic "Pomodoro Timer" "Work session finished! $msg"
      else
        type="work"; remaining_time=1500
        notify-send -u critical -i timer-symbolic "Pomodoro Timer" "Break finished! Back to work."
      fi
      status="paused"; target_time=0
      save_state
      remaining=$remaining_time
    fi
  else
    remaining=$remaining_time
  fi

  min=$((remaining / 60))
  sec=$((remaining % 60))
  time_str=$(printf "%02d:%02d" $min $sec)

  if [ "$status" = "idle" ]; then
    icon="󱎫"; text=""; tooltip="Click to start Work session (25m)"; class="idle"
  elif [ "$status" = "paused" ]; then
    if [ "$type" = "work" ]; then
      icon="󱎫"; text="$time_str (Paused)"; tooltip="Paused Work session. Click to resume."; class="paused"
    else
      icon="󰔛"; text="$time_str (Paused)"; tooltip="Paused Break session. Click to resume."; class="paused"
    fi
  elif [ "$status" = "running" ]; then
    if [ "$type" = "work" ]; then
      icon="󱎫"; text="$time_str"; tooltip="Working... Click to pause."; class="work"
    else
      icon="󰔛"; text="$time_str"; tooltip="On break... Click to pause."; class="break"
    fi
  fi

  if [ -n "$text" ]; then display_text="$icon $text"; else display_text="$icon"; fi
  FULL_TOOLTIP=$(printf "%s\nCycle: %s" "$tooltip" "$cycles")
  jq -n -c --arg text "$display_text" --arg tooltip "$FULL_TOOLTIP" --arg class "$class" '{text: $text, tooltip: $tooltip, class: $class}'
}

case "$1" in
  toggle) toggle ;;
  reset) reset ;;
  skip) skip ;;
  status|*) status ;;
esac
