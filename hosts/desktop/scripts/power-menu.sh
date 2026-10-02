#!/usr/bin/env bash
# Power menu via rofi
options="🔒 Lock Screen\n💤 Suspend\n🔋 Toggle Ultra Low Power Mode\n🔄 Reboot System\n⚡ Shutdown System\n🚪 Exit Hyprland Session"
selected=$(echo -e "$options" | rofi -dmenu -i -p "Power Menu" -font "Outfit 12" -theme-str 'window {width: 450px;}')
case "$selected" in
  *"Shutdown"*) systemctl poweroff ;;
  *"Reboot"*) systemctl reboot ;;
  *"Suspend"*) loginctl lock-session && systemctl suspend ;;
  *"Lock"*) loginctl lock-session ;;
  *"Ultra Low Power"*) power-mode toggle ;;
  *"Exit"*) hyprctl dispatch exit ;;
esac
