#!/usr/bin/env bash
# tablet-display: Manage virtual headless display output in Hyprland for Moonlight/Sunshine tablet streaming
set -euo pipefail

ACTION="${1:-toggle}"
RES="${2:-1920x1200@60}"
SCALE="${3:-1}"

HEADLESS_ACTIVE=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.name | startswith("HEADLESS")) | .name' | head -n 1 || true)

case "$ACTION" in
  on)
    if [ -n "$HEADLESS_ACTIVE" ]; then
      echo "Headless tablet display already active: $HEADLESS_ACTIVE"
      exit 0
    fi
    echo "Creating virtual headless tablet display..."
    hyprctl output create headless >/dev/null 2>&1 || true
    sleep 0.5
    NEW_OUTPUT=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.name | startswith("HEADLESS")) | .name' | head -n 1 || true)
    if [ -n "$NEW_OUTPUT" ]; then
      hyprctl keyword monitor "$NEW_OUTPUT,$RES,auto,$SCALE" >/dev/null 2>&1 || true
      echo "Virtual display $NEW_OUTPUT activated ($RES, scale $SCALE)."
      swayosd-client --custom-message "Tablet Display Active ($NEW_OUTPUT)" 2>/dev/null || true
    fi
    ;;
  off)
    if [ -z "$HEADLESS_ACTIVE" ]; then
      echo "No virtual headless display is currently active."
      exit 0
    fi
    echo "Removing virtual display $HEADLESS_ACTIVE..."
    hyprctl output remove "$HEADLESS_ACTIVE" >/dev/null 2>&1 || true
    swayosd-client --custom-message "Tablet Display Disconnected" 2>/dev/null || true
    ;;
  toggle)
    if [ -n "$HEADLESS_ACTIVE" ]; then
      "$0" off
    else
      "$0" on "$RES" "$SCALE"
    fi
    ;;
  status)
    if [ -n "$HEADLESS_ACTIVE" ]; then
      echo "Active: $HEADLESS_ACTIVE"
    else
      echo "Inactive"
    fi
    ;;
  *)
    echo "Usage: tablet-display [on|off|toggle|status] [resolution] [scale]"
    exit 1
    ;;
esac
