#!/usr/bin/env bash
# Resize tiled windows to specific width/height ratios

direction="$1"
target_percent="$2"

active_win=$(hyprctl activewindow -j)
if [ -z "$active_win" ] || [ "$active_win" = "null" ]; then
  exit 0
fi

active_addr=$(echo "$active_win" | jq -r '.address')
active_workspace=$(echo "$active_win" | jq -r '.workspace.id')
x_active=$(echo "$active_win" | jq -r '.at[0]')
y_active=$(echo "$active_win" | jq -r '.at[1]')
w_active=$(echo "$active_win" | jq -r '.size[0]')
h_active=$(echo "$active_win" | jq -r '.size[1]')

monitor_id=$(echo "$active_win" | jq -r '.monitor')
monitor_info=$(hyprctl monitors -j | jq -r ".[] | select(.id == $monitor_id)")
monitor_width=$(echo "$monitor_info" | jq -r '.width')
monitor_height=$(echo "$monitor_info" | jq -r '.height')

sibling_coords=$(hyprctl clients -j | jq -r ".[] | select(.workspace.id == $active_workspace and .address != \"$active_addr\") | \"\(.address) \(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])\"" | head -n 1)
if [ -z "$sibling_coords" ]; then
  exit 0
fi

addr_sibling=$(echo "$sibling_coords" | cut -d' ' -f1)
x_sibling=$(echo "$sibling_coords" | cut -d' ' -f2)
y_sibling=$(echo "$sibling_coords" | cut -d' ' -f3)
w_sibling=$(echo "$sibling_coords" | cut -d' ' -f4)
h_sibling=$(echo "$sibling_coords" | cut -d' ' -f5)

if [ "$x_active" -lt "$x_sibling" ]; then
  addr_left="$active_addr"; w_left="$w_active"
else
  addr_left="$addr_sibling"; w_left="$w_sibling"
fi

if [ "$y_active" -lt "$y_sibling" ]; then
  addr_top="$active_addr"; h_top="$h_active"
else
  addr_top="$addr_sibling"; h_top="$h_sibling"
fi

if [ "$direction" = "width" ]; then
  target_width=$(( monitor_width * target_percent / 100 ))
  dw=$(( target_width - w_left ))
  hyprctl dispatch focuswindow "address:$addr_left"
  hyprctl dispatch resizeactive "$dw" 0
  hyprctl dispatch focuswindow "address:$active_addr"
elif [ "$direction" = "height" ]; then
  target_height=$(( monitor_height * target_percent / 100 ))
  dh=$(( target_height - h_top ))
  hyprctl dispatch focuswindow "address:$addr_top"
  hyprctl dispatch resizeactive 0 "$dh"
  hyprctl dispatch focuswindow "address:$active_addr"
fi
