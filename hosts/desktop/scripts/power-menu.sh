#!/usr/bin/env bash
# Power menu via rofi with high quality Nerd Font icons
options="󰌾 Lock Screen\n󰒲 Suspend\n󰌪 Toggle Ultra Low Power Mode\n󰑓 Reboot System\n󰐥 Shutdown System\n󰗼 Exit Hyprland Session"
selected=$(echo -e "$options" | rofi -dmenu -i -p "Power Menu" -font "Outfit 12" -theme-str 'window {width: 480px;} listview {lines: 6;} element {padding: 8px 12px;}')
case "$selected" in
  *"Shutdown"*) systemctl poweroff ;;
  *"Reboot"*) systemctl reboot ;;
  *"Suspend"*) loginctl lock-session && systemctl suspend ;;
  *"Lock"*) loginctl lock-session ;;
  *"Ultra Low Power"*) power-mode toggle ;;
  *"Exit"*) hyprctl dispatch exit ;;
esac
