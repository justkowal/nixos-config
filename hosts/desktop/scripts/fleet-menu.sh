#!/usr/bin/env bash
# Interactive Fleet and Homelab Services Launcher via Rofi

set +e

MENU_ITEMS="󰖟 Homelab Portal (Glance) — https://lab
󰈸 Status & Uptime Kuma — https://status.lab
󰊢 Forgejo Git Repositories — https://git.lab
󰑮 Woodpecker CI Pipelines — https://ci.lab
󰌆 Kanidm Identity Provider — https://idm.lab
󰌾 Vaultwarden Password Manager — https://vault.lab
󰃁 Shiori Bookmarks & Archives — https://bookmarks.lab
󰞷 SSH into RPi4 Homelab Server (192.168.1.22)
󰌢 SSH into ThinkPad Laptop (192.168.1.20)
󰚰 Review Staged NixOS System Update
󰡏 Run Fleet Health Probe"

CHOICE=$(echo -e "$MENU_ITEMS" | rofi -dmenu -i -p "Fleet & Services" -font "Outfit 12" -theme-str 'window {width: 680px;} listview {lines: 11;} element {padding: 8px 12px;}')

case "$CHOICE" in
  *"Homelab Portal"*) xdg-open "https://lab" & ;;
  *"Status & Uptime"*) xdg-open "https://status.lab" & ;;
  *"Forgejo"*) xdg-open "https://git.lab" & ;;
  *"Woodpecker"*) xdg-open "https://ci.lab" & ;;
  *"Kanidm"*) xdg-open "https://idm.lab" & ;;
  *"Vaultwarden"*) xdg-open "https://vault.lab" & ;;
  *"Shiori"*) xdg-open "https://bookmarks.lab" & ;;
  *"SSH into RPi4"*) kitty --title "SSH: nixos-rpi4" -e ssh justkowal@192.168.1.22 & ;;
  *"SSH into ThinkPad"*) kitty --title "SSH: thinkpad-laptop" -e ssh justkowal@192.168.1.20 & ;;
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
