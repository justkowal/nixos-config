#!/usr/bin/env bash
# Interactive Fleet and Homelab Services Launcher via Rofi
# Dynamic host and IP resolution (Zero hardcoded IPs)

set +e

CURRENT_HOST=$(hostname)
IS_LAPTOP=false
if [[ "$CURRENT_HOST" == *"laptop"* || "$CURRENT_HOST" == *"thinkpad"* || "$CURRENT_HOST" == *"t14s"* ]]; then
  IS_LAPTOP=true
fi

# Dynamically resolve node IP (Checks local DNS, then Tailscale mesh)
resolve_target_ip() {
  local name="$1"
  local ip=""
  for cand in "${name}.lab" "${name}.local" "$name"; do
    ip=$(getent hosts "$cand" 2>/dev/null | awk '{print $1}' | head -n1)
    if [ -n "$ip" ] && [[ ! "$ip" =~ ^127\. ]]; then
      if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        echo "$ip"
        return 0
      fi
    fi
  done
  if command -v tailscale >/dev/null 2>&1; then
    ip=$(tailscale ip -4 "$name" 2>/dev/null | head -n1)
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
  fi
  echo "${ip:-$name}"
}

if [ "$IS_LAPTOP" = true ]; then
  REMOTE_PEER_LABEL="󰞷 SSH into Desktop Workstation"
else
  REMOTE_PEER_LABEL="󰌢 SSH into ThinkPad Laptop"
fi

MENU_ITEMS="󰖟 Homelab Portal (Glance) — https://lab
󰈸 Status & Uptime Kuma — https://status.lab
󰊢 Forgejo Git Repositories — https://git.lab
󰑮 Woodpecker CI Pipelines — https://ci.lab
󰌆 Kanidm Identity Provider — https://idm.lab
󰌾 Vaultwarden Password Manager — https://vault.lab
󰃁 Shiori Bookmarks & Archives — https://bookmarks.lab
󰒋 SSH into RPi4 Homelab Server
${REMOTE_PEER_LABEL}
󰕮 System Control Center (GUI)
󰍽 Seamless Mouse & Desk Layout Setup (GUI)
󰹑 Tablet Display Streaming Studio (GUI)
󰒋 Deployment Fleet Control Center (GUI)
󰚰 Review Staged NixOS System Update
󰡏 Run Fleet Health Probe"

CHOICE=$(echo -e "$MENU_ITEMS" | rofi -dmenu -i -p "Fleet & Services" -font "Outfit 12" -theme-str 'window {width: 680px;} listview {lines: 15;} element {padding: 8px 12px;}')

case "$CHOICE" in
  *"Homelab Portal"*) xdg-open "https://lab" & ;;
  *"Status & Uptime"*) xdg-open "https://status.lab" & ;;
  *"Forgejo"*) xdg-open "https://git.lab" & ;;
  *"Woodpecker"*) xdg-open "https://ci.lab" & ;;
  *"Kanidm"*) xdg-open "https://idm.lab" & ;;
  *"Vaultwarden"*) xdg-open "https://vault.lab" & ;;
  *"Shiori"*) xdg-open "https://bookmarks.lab" & ;;
  *"SSH into RPi4"*)
    RPI_IP=$(resolve_target_ip "nixos-rpi4")
    kitty --title "SSH: nixos-rpi4 ($RPI_IP)" -e ssh "justkowal@$RPI_IP" &
    ;;
  *"SSH into ThinkPad"*)
    LAP_IP=$(resolve_target_ip "thinkpad-t14s-gen1-amd")
    kitty --title "SSH: thinkpad-laptop ($LAP_IP)" -e ssh "justkowal@$LAP_IP" &
    ;;
  *"SSH into Desktop"*)
    DESK_IP=$(resolve_target_ip "nixos-desktop")
    kitty --title "SSH: nixos-desktop ($DESK_IP)" -e ssh "justkowal@$DESK_IP" &
    ;;
  *"System Control Center"*) control-center-gui & ;;
  *"Seamless Mouse"*) lan-mouse-gui & ;;
  *"Tablet Display"*) tablet-display-gui & ;;
  *"Deployment Fleet Control"*) fleet-manager-gui & ;;
  *"Review Staged"*)
    if [ -x "$(command -v nixos-update-apply)" ]; then
      kitty --class update_review -e nixos-update-apply &
    else
      notify-send "NixOS Update" "No staged update review tool found." &
    fi
    ;;
  *"Health Probe"*)
    PROBE_RESULT=$(fleet-status probe)
    notify-send -t 6000 "󰒋 Fleet Health Probe" "$PROBE_RESULT" &
    ;;
esac
