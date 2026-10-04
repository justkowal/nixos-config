#!/usr/bin/env bash
# Fleet status monitor for Waybar (JSON output)
# Non-blocking, dynamic peer discovery across deployment nodes (Zero hardcoded IPs)

set +e
set +o pipefail 2>/dev/null || true

CURRENT_HOST=$(hostname)
IS_LAPTOP=false
if [[ "$CURRENT_HOST" == *"laptop"* || "$CURRENT_HOST" == *"thinkpad"* || "$CURRENT_HOST" == *"t14s"* ]]; then
  IS_LAPTOP=true
fi

# Dynamically resolve node IP (Checks local DNS, then Tailscale mesh)
resolve_target_ip() {
  local name="$1"
  local ip=""

  # 1. Check local LAN DNS candidates (.lab, .local, name)
  for cand in "${name}.lab" "${name}.local" "$name"; do
    ip=$(getent hosts "$cand" 2>/dev/null | awk '{print $1}' | head -n1)
    if [ -n "$ip" ] && [[ ! "$ip" =~ ^127\. ]]; then
      # Test if LAN IP responds
      if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        echo "$ip"
        return 0
      fi
    fi
  done

  # 2. Check Tailscale mesh IP
  if command -v tailscale >/dev/null 2>&1; then
    ip=$(tailscale ip -4 "$name" 2>/dev/null | head -n1)
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
  fi

  echo "${ip:-$name}"
}

# Dynamically resolve remote nodes based on current machine
if [ "$IS_LAPTOP" = true ]; then
  REMOTE1_LABEL="󰞷 nixos-desktop    (Workstation)"
  REMOTE1_IP=$(resolve_target_ip "nixos-desktop")
else
  REMOTE1_LABEL="󰌢 thinkpad-laptop  (Mobile Client)"
  REMOTE1_IP=$(resolve_target_ip "thinkpad-t14s-gen1-amd")
fi

RP_IP=$(resolve_target_ip "nixos-rpi4")

RP_STATUS="offline"
RP_PING=""
RP_WEB="Offline"
REMOTE1_STATUS="offline"
REMOTE1_PING=""

# Probe RPi4 (Homelab server)
if [ -n "$RP_IP" ]; then
  if PING_RES=$(ping -c 1 -W 1 "$RP_IP" 2>&1); then
    RP_STATUS="online"
    RP_PING=$(echo "$PING_RES" | awk -F"/" '/rtt/ {print $5}')
    if curl -k -s -I --connect-timeout 1 -m 1 --resolve lab:443:"$RP_IP" https://lab >/dev/null 2>&1; then
      RP_WEB="Online (HTTP 200)"
    else
      RP_WEB="Online"
    fi
  fi
fi

# Probe Remote peer (Desktop or Laptop)
if [ -n "$REMOTE1_IP" ]; then
  if PING_RES=$(ping -c 1 -W 1 "$REMOTE1_IP" 2>&1); then
    REMOTE1_STATUS="online"
    REMOTE1_PING=$(echo "$PING_RES" | awk -F"/" '/rtt/ {print $5}')
  fi
fi

UP_COUNT=1
[ "$RP_STATUS" = "online" ] && ((UP_COUNT++))
[ "$REMOTE1_STATUS" = "online" ] && ((UP_COUNT++))

if [ "${1:-}" = "probe" ]; then
  if [ "$IS_LAPTOP" = true ]; then
    printf "Laptop: Online (Local)\nDesktop: %s (Ping: %sms | IP: %s)\nRPi4 Core: %s (Ping: %sms | IP: %s)\nNodes Active: %d/3" \
      "$REMOTE1_STATUS" "${REMOTE1_PING:-timeout}" "$REMOTE1_IP" "$RP_STATUS" "${RP_PING:-timeout}" "$RP_IP" "$UP_COUNT"
  else
    printf "Desktop: Online (Local)\nRPi4 Core: %s (Ping: %sms | IP: %s)\nThinkPad Laptop: %s (Ping: %sms | IP: %s)\nNodes Active: %d/3" \
      "$RP_STATUS" "${RP_PING:-timeout}" "$RP_IP" "$REMOTE1_STATUS" "${REMOTE1_PING:-timeout}" "$REMOTE1_IP" "$UP_COUNT"
  fi
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
REMOTE1_PING_FMT=${REMOTE1_PING:-"timeout"}

if [ "$IS_LAPTOP" = true ]; then
  TOOLTIP=$(cat <<EOF
󰒋 NixOS Deployment Fleet
󰌢 thinkpad-laptop (ThinkPad T14s) [Active Host]
󰞷 nixos-desktop (Workstation) [${REMOTE1_IP}]
  Status: $REMOTE1_STATUS · Latency: ${REMOTE1_PING_FMT}ms
󰒋 nixos-rpi4 (Homelab Core) [${RP_IP}]
  Status: $RP_STATUS · Latency: ${RP_PING_FMT}ms
  Portal: $RP_WEB (https://lab)
─────────────────────────────────────
Click: Open Fleet Manager
Right-Click: Fleet Command Menu
EOF
)
else
  TOOLTIP=$(cat <<EOF
󰒋 NixOS Deployment Fleet
󰞷 nixos-desktop (Workstation) [Active Host]
󰒋 nixos-rpi4 (Homelab Core) [${RP_IP}]
  Status: $RP_STATUS · Latency: ${RP_PING_FMT}ms
  Portal: $RP_WEB (https://lab)
󰌢 thinkpad-laptop (ThinkPad T14s) [${REMOTE1_IP}]
  Status: $REMOTE1_STATUS · Latency: ${REMOTE1_PING_FMT}ms
─────────────────────────────────────
Click: Open Fleet Manager
Right-Click: Fleet Command Menu
EOF
)
fi

jq -n -c \
  --arg text "$BADGE_TEXT" \
  --arg class "$BADGE_CLASS" \
  --arg tooltip "$TOOLTIP" \
  '{text: $text, class: $class, tooltip: $tooltip}'
