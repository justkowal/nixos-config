#!/usr/bin/env bash

# Find Picture-in-Picture window address
pip_address=$(hyprctl clients -j | jq -r '.[] | select(.title=="Picture-in-Picture") | .address')

if [ -z "$pip_address" ]; then
    # No PIP window exists
    printf '%s\n' '{"text": "", "class": "empty"}'
    exit 0
fi

# Get its workspace
workspace=$(hyprctl clients -j | jq -r ".[] | select(.address==\"$pip_address\") | .workspace.name")

if [ "${1:-}" == "toggle" ]; then
    if [[ "$workspace" == "special:pip" ]]; then
        # Move it to current workspace
        current_workspace=$(hyprctl activeworkspace -j | jq -r '.id')
        hyprctl dispatch movetoworkspace "$current_workspace,address:$pip_address"
    else
        # Move it to special workspace
        hyprctl dispatch movetoworkspacesilent special:pip,address:"$pip_address"
    fi
else
    if [[ "$workspace" == "special:pip" ]]; then
        printf '%s\n' '{"text": "󰗡 ", "class": "hidden", "tooltip": "PIP Hidden\\nClick to show"}'
    else
        printf '%s\n' '{"text": "󰗡 ", "class": "visible", "tooltip": "PIP Visible\\nClick to hide"}'
    fi
fi
