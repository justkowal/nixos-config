#!/usr/bin/env bash
# Wake Desktop Workstation via Pi local network or LAN
set -euo pipefail

TARGET_MAC="10:ff:e0:40:7d:6e"
MODE="${1:-desktop}"

case "$MODE" in
  desktop)
    echo "󱐋 Waking Desktop into Workstation GUI (Hyprland) via Pi..."
    curl -s -X POST http://nixos-rpi4.lab:9100/hooks/wake-desktop >/dev/null 2>&1 || \
      ssh -o ConnectTimeout=3 justkowal@nixos-rpi4.lab wake-desktop >/dev/null 2>&1 || true
    wakeonlan "$TARGET_MAC" >/dev/null 2>&1 || true
    echo "󰄲 Wake signal dispatched (target: desktop)"
    ;;
  server)
    echo "󱐋 Waking Desktop into Scale-to-Zero Server mode via Pi..."
    curl -s -X POST http://nixos-rpi4.lab:9100/hooks/wake-worker >/dev/null 2>&1 || \
      ssh -o ConnectTimeout=3 justkowal@nixos-rpi4.lab wake-worker >/dev/null 2>&1 || true
    wakeonlan "$TARGET_MAC" >/dev/null 2>&1 || true
    echo "󰄲 Wake signal dispatched (target: server)"
    ;;
  wol|lan)
    echo "󱐋 Sending direct WoL packet via Pi & LAN..."
    curl -s -X POST http://nixos-rpi4.lab:9100/hooks/wake-wol >/dev/null 2>&1 || \
      ssh -o ConnectTimeout=3 justkowal@nixos-rpi4.lab wake-wol >/dev/null 2>&1 || true
    wakeonlan "$TARGET_MAC" >/dev/null 2>&1 || true
    echo "󰄲 WoL magic packet broadcasted"
    ;;
  *)
    echo "Usage: wake-desktop [desktop|server|lan]"
    exit 1
    ;;
esac
