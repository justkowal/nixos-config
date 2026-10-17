#!/usr/bin/env bash
# batmon: Apple HIG ThinkPad Battery & Power Telemetry Monitor
# Displays battery health, cycles, live charging wattage, and charge limits.

set -euo pipefail

BAT_DIR="/sys/class/power_supply/BAT0"
if [ ! -d "$BAT_DIR" ]; then
  BAT_DIR="/sys/class/power_supply/BAT1"
fi

if [ ! -d "$BAT_DIR" ]; then
  echo "Error: No battery found under /sys/class/power_supply/" >&2
  exit 1
fi

get_raw() {
  local file="$BAT_DIR/$1"
  if [ -f "$file" ]; then
    cat "$file" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

set_thresholds() {
  local start="$1"
  local stop="$2"
  local changed=0

  for f in "$BAT_DIR/charge_start_threshold" "$BAT_DIR/charge_control_start_threshold"; do
    if [ -w "$f" ]; then
      echo "$start" > "$f" 2>/dev/null && changed=1 || true
    fi
  done
  for f in "$BAT_DIR/charge_stop_threshold" "$BAT_DIR/charge_control_end_threshold"; do
    if [ -w "$f" ]; then
      echo "$stop" > "$f" 2>/dev/null && changed=1 || true
    fi
  done

  if [ "$changed" -eq 1 ]; then
    echo "✓ Battery thresholds updated: Start at ${start}%, Stop at ${stop}%"
  else
    echo "Note: Writing directly to sysfs requires permission. Running via tlp or sudo..."
    if command -v tlp >/dev/null 2>&1; then
      if [ "$stop" -ge 100 ]; then
        sudo tlp fullcharge BAT0 2>/dev/null || true
      fi
    fi
  fi
}

read_telemetry() {
  CAPACITY=$(get_raw "capacity")
  STATUS=$(cat "$BAT_DIR/status" 2>/dev/null || echo "Unknown")
  CYCLES=$(get_raw "cycle_count")
  
  ENERGY_NOW=$(get_raw "energy_now")
  ENERGY_FULL=$(get_raw "energy_full")
  ENERGY_DESIGN=$(get_raw "energy_full_design")
  POWER_NOW=$(get_raw "power_now")
  VOLTAGE_NOW=$(get_raw "voltage_now")

  # Calculate health percentage
  if [ "$ENERGY_DESIGN" -gt 0 ]; then
    HEALTH_PCT=$(awk "BEGIN {printf \"%.1f\", ($ENERGY_FULL * 100.0) / $ENERGY_DESIGN}")
    WH_FULL=$(awk "BEGIN {printf \"%.2f\", $ENERGY_FULL / 1000000}")
    WH_DESIGN=$(awk "BEGIN {printf \"%.2f\", $ENERGY_DESIGN / 1000000}")
    WH_NOW=$(awk "BEGIN {printf \"%.2f\", $ENERGY_NOW / 1000000}")
  else
    HEALTH_PCT="100.0"
    WH_FULL="0"
    WH_DESIGN="0"
    WH_NOW="0"
  fi

  # Calculate live wattage
  WATTS=$(awk "BEGIN {printf \"%.2f\", $POWER_NOW / 1000000}")
  VOLTS=$(awk "BEGIN {printf \"%.2f\", $VOLTAGE_NOW / 1000000}")
  if [ "$VOLTAGE_NOW" -gt 0 ]; then
    AMPS=$(awk "BEGIN {printf \"%.2f\", $POWER_NOW / $VOLTAGE_NOW}")
  else
    AMPS="0.00"
  fi

  # Thresholds
  THRESH_START=$(get_raw "charge_control_start_threshold")
  [ "$THRESH_START" = "0" ] && THRESH_START=$(get_raw "charge_start_threshold")
  THRESH_STOP=$(get_raw "charge_control_end_threshold")
  [ "$THRESH_STOP" = "0" ] && THRESH_STOP=$(get_raw "charge_stop_threshold")

  # AC Status
  AC_ONLINE="0"
  if [ -f /sys/class/power_supply/AC/online ]; then
    AC_ONLINE=$(cat /sys/class/power_supply/AC/online 2>/dev/null || echo "0")
  fi

  # Time estimate via upower if available
  TIME_ESTIMATE=""
  if command -v upower >/dev/null 2>&1; then
    local dev_path
    dev_path=$(upower -e | grep -E "battery|BAT" | head -n1 || true)
    if [ -n "$dev_path" ]; then
      local u_info
      u_info=$(upower -i "$dev_path" 2>/dev/null || true)
      if [ "$STATUS" = "Charging" ]; then
        TIME_ESTIMATE=$(echo "$u_info" | awk '/time to full/ {for(i=4;i<=NF;++i) printf "%s ", $i; print ""}' | sed 's/[ \t]*$//')
      elif [ "$STATUS" = "Discharging" ]; then
        TIME_ESTIMATE=$(echo "$u_info" | awk '/time to empty/ {for(i=4;i<=NF;++i) printf "%s ", $i; print ""}' | sed 's/[ \t]*$//')
      fi
    fi
  fi
}

draw_bar() {
  local pct="$1"
  local width=22
  local filled=$(( (pct * width) / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  local empty=$(( width - filled ))
  
  local bar=""
  for _ in $(seq 1 "$filled"); do bar="${bar}█"; done
  for _ in $(seq 1 "$empty"); do bar="${bar}░"; done
  echo "$bar"
}

print_cli() {
  read_telemetry

  # ANSI Apple palette (Semantic SF styles)
  local BOLD="\033[1m"
  local RESET="\033[0m"
  local GREEN="\033[38;2;52;199;89m"
  local ORANGE="\033[38;2;255;149;0m"
  local BLUE="\033[38;2;0;122;255m"
  local GRAY="\033[38;2;142;142;147m"
  local ACCENT="\033[38;2;175;82;222m"

  local bar
  bar=$(draw_bar "$CAPACITY")

  local status_color="$GREEN"
  [ "$STATUS" = "Discharging" ] && status_color="$ORANGE"
  [ "$STATUS" = "Not charging" ] && status_color="$GRAY"

  local health_condition="Normal"
  local health_color="$GREEN"
  if awk "BEGIN {exit !($HEALTH_PCT < 80.0)}"; then
    health_condition="Service Recommended"
    health_color="$ORANGE"
  fi

  local pwr_sign=""
  if [ "$STATUS" = "Charging" ]; then
    pwr_sign="+"
  elif [ "$STATUS" = "Discharging" ]; then
    pwr_sign="-"
  fi

  echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${RESET}"
  echo -e "  ${BOLD}󰚥  ThinkPad Battery & Power Telemetry${RESET}  ${GRAY}(Apple HIG Inspector)${RESET}"
  echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${RESET}"
  echo -e "  ${BOLD}Charge Level:${RESET}        ${status_color}${bar}${RESET}  ${BOLD}${CAPACITY}%${RESET} ${status_color}[${STATUS}]${RESET}"
  
  if [ "$AC_ONLINE" = "1" ]; then
    echo -e "  ${BOLD}Power Source:${RESET}        ${GREEN}Connected AC Mains${RESET} (USB-C Power Delivery)"
  else
    echo -e "  ${BOLD}Power Source:${RESET}        ${ORANGE}Internal Battery Power${RESET}"
  fi

  echo -e "  ${BOLD}Power Flow / Speed:${RESET}  ${status_color}${pwr_sign}${WATTS} W${RESET}  ${GRAY}(${VOLTS} V · ${AMPS} A)${RESET}"

  if [ -n "$TIME_ESTIMATE" ]; then
    if [ "$STATUS" = "Charging" ]; then
      echo -e "  ${BOLD}Time Until Full:${RESET}     ${BLUE}${TIME_ESTIMATE}${RESET}"
    else
      echo -e "  ${BOLD}Remaining Runtime:${RESET}   ${BLUE}${TIME_ESTIMATE}${RESET}"
    fi
  fi

  echo -e "${GRAY}───────────────────────────────────────────────────────────────────${RESET}"
  echo -e "  ${BOLD}Battery Health:${RESET}      ${health_color}${HEALTH_PCT}%${RESET}  [${health_color}${health_condition}${RESET}]"
  echo -e "  ${BOLD}Cycle Count:${RESET}         ${BOLD}${CYCLES}${RESET} cycles"
  echo -e "  ${BOLD}Charge Capacity:${RESET}     ${WH_FULL} Wh / ${WH_DESIGN} Wh ${GRAY}(Design Full: 57.02 Wh)${RESET}"
  echo -e "  ${BOLD}Current Stored:${RESET}      ${WH_NOW} Wh"

  local mode_desc="Standard (100% Full)"
  if [ "$THRESH_STOP" != "0" ] && [ "$THRESH_STOP" -lt 100 ]; then
    mode_desc="Conservation Mode (${THRESH_START}% - ${THRESH_STOP}%)"
  fi
  echo -e "  ${BOLD}Threshold Limits:${RESET}    ${ACCENT}${mode_desc}${RESET}"
  echo -e "${BOLD}═══════════════════════════════════════════════════════════════════${RESET}"
  echo -e "  ${GRAY}Actions: batmon --trip (Charge to 100%) | batmon --conserve (85-90%) | batmon --gauge${RESET}"
}

print_json() {
  read_telemetry
  cat <<EOF
{
  "capacity": $CAPACITY,
  "status": "$STATUS",
  "cycles": $CYCLES,
  "health_pct": $HEALTH_PCT,
  "power_watts": $WATTS,
  "voltage_volts": $VOLTS,
  "current_amps": $AMPS,
  "wh_now": $WH_NOW,
  "wh_full": $WH_FULL,
  "wh_design": $WH_DESIGN,
  "threshold_start": $THRESH_START,
  "threshold_stop": $THRESH_STOP,
  "ac_online": $AC_ONLINE,
  "time_estimate": "$TIME_ESTIMATE"
}
EOF
}

case "${1:-}" in
  --json|-j)
    print_json
    ;;
  --watch|-w)
    while true; do
      clear
      print_cli
      sleep 1
    done
    ;;
  --trip|--boost|--full)
    set_thresholds 95 100
    ;;
  --conserve|--normal)
    set_thresholds 85 90
    ;;
  --gauge|-g)
    if command -v thinkdot >/dev/null 2>&1; then
      thinkdot gauge
    else
      echo "thinkdot command not found."
    fi
    ;;
  --gui)
    if command -v accubattery-gui >/dev/null 2>&1; then
      exec accubattery-gui
    fi
    ;;
  --help|-h)
    echo "Usage: batmon [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (none)            Print formatted Apple HIG battery telemetry report"
    echo "  --gui             Launch AccuBattery Studio graphical interface"
    echo "  --watch, -w       Live continuous telemetry monitor (refreshes every 1s)"
    echo "  --json, -j        Output machine-readable telemetry JSON"
    echo "  --trip, --boost   Temporarily allow charging to 100% for travel / trip mode"
    echo "  --conserve        Restore 85%-90% battery longevity conservation threshold"
    echo "  --gauge, -g       Trigger physical ThinkPad lid LED dot percentage flash"
    echo "  --help, -h        Show this help message"
    ;;
  *)
    print_cli
    ;;
esac
