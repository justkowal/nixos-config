#!/usr/bin/env bash
# Fleet status monitor for Waybar (JSON output)
# Non-blocking, fast timeout probes across deployment nodes

set +e
set +o pipefail 2>/dev/null || true

RP_IP="192.168.1.22"
LAP_IP="192.168.1.20"

RP_STATUS="offline"
RP_PING=""
RP_WEB="Offline"
LAP_STATUS="offline"
LAP_PING=""

# Probe RPi4 (Homelab server)
if PING_RES=$(ping -c 1 -W 1 "$RP_IP" 2>&1); then
  RP_STATUS="online"
  RP_PING=$(echo "$PING_RES" | awk -F"/" '/rtt/ {print $5}')
  if curl -k -s -I --connect-timeout 1 -m 1 --resolve lab:443:"$RP_IP" https://lab >/dev/null 2>&1; then
    RP_WEB="Online (HTTP 200)"
  else
    RP_WEB="Web Port Timeout"
  fi
fi

# Probe Laptop (ThinkPad T14s)
if PING_RES=$(ping -c 1 -W 1 "$LAP_IP" 2>&1); then
  LAP_STATUS="online"
  LAP_PING=$(echo "$PING_RES" | awk -F"/" '/rtt/ {print $5}')
fi

UP_COUNT=1
[ "$RP_STATUS" = "online" ] && ((UP_COUNT++))
[ "$LAP_STATUS" = "online" ] && ((UP_COUNT++))

if [ "$1" = "probe" ]; then
  printf "Desktop: Online\nRPi4 Core: %s (Ping: %sms | Portal: %s)\nThinkPad Laptop: %s (Ping: %sms)\nNodes Active: %d/3" \
    "$RP_STATUS" "${RP_PING:-timeout}" "$RP_WEB" "$LAP_STATUS" "${LAP_PING:-timeout}" "$UP_COUNT"
  exit 0
fi

if [ "$UP_COUNT" -eq 3 ]; then
  BADGE_CLASS="online"
  BADGE_TEXT="󰒋 Fleet 3/3"
elif [ "$UP_COUNT" -eq 2 ]; then
  BADGE_CLASS="partial"
  BADGE_TEXT="󰒋 Fleet 2/3"
else
  BADGE_CLASS="warning"
  BADGE_TEXT="󰒋 Fleet 1/3"
fi

RP_PING_FMT=${RP_PING:-"timeout"}
LAP_PING_FMT=${LAP_PING:-"timeout"}

TOOLTIP=$(cat <<EOF
── 󰒋 NixOS Deployment Fleet ─────────────────────
󰞷 nixos-desktop    (Workstation)    [Local Active]
  ├─ CPU: AMD Ryzen 7 5700X | GPU: RX 6700 XT
  └─ ROCm HIP Accelerated | Hyprland Wayland

󰒋 nixos-rpi4       (Homelab Core)   [$RP_IP]
  ├─ Status: $RP_STATUS | Latency: ${RP_PING_FMT}ms
  ├─ Web Portal: $RP_WEB (https://lab)
  └─ Services: Glance, Git, CI, Vault, IDM, Kuma

󰌢 thinkpad-laptop  (Mobile Client)  [$LAP_IP]
  ├─ Status: $LAP_STATUS | Latency: ${LAP_PING_FMT}ms
  └─ ThinkPad T14s Gen 1 AMD | Tailscale Mesh
─────────────────────────────────────────────────
󰍽 Left-Click: Open Glance Portal (https://lab)
󰍽 Right-Click: Fleet Command & Services Menu
󰍽 Middle-Click: Quick Probe Latencies
EOF
)

jq -n -c \
  --arg text "$BADGE_TEXT" \
  --arg class "$BADGE_CLASS" \
  --arg tooltip "$TOOLTIP" \
  '{text: $text, class: $class, tooltip: $tooltip}'
