#!/usr/bin/env bash
# Unified CPU + GPU sensor monitor for Waybar (JSON output)

set +e
set +o pipefail 2>/dev/null || true

# CPU usage over 0.5 seconds
read -r _ user nice system idle iowait irq softirq steal _ _ < /proc/stat
prev_idle=$((idle + iowait))
prev_non_idle=$((user + nice + system + irq + softirq + steal))
prev_total=$((prev_idle + prev_non_idle))

sleep 0.5

read -r _ user nice system idle iowait irq softirq steal _ _ < /proc/stat
idle=$((idle + iowait))
non_idle=$((user + nice + system + irq + softirq + steal))
total=$((idle + non_idle))

total_diff=$((total - prev_total))
idle_diff=$((idle - prev_idle))

if [ "$total_diff" -ne 0 ]; then
    CPU_UTIL=$(( (total_diff - idle_diff) * 100 / total_diff ))
else
    CPU_UTIL=0
fi

# CPU temperature (k10temp / coretemp / zenpower)
CPU_TEMP=0
CPU_TEMP_FILE=""
for name_file in /sys/class/hwmon/hwmon*/name; do
    if [ -f "$name_file" ]; then
        name=$(cat "$name_file" 2>/dev/null)
        if [ "$name" = "k10temp" ] || [ "$name" = "coretemp" ] || [ "$name" = "zenpower" ]; then
            dir=$(dirname "$name_file")
            if [ -f "$dir/temp1_input" ]; then
                CPU_TEMP_FILE="$dir/temp1_input"
                break
            fi
        fi
    fi
done

# Fallback if specific sensor driver name not found
if [ -z "$CPU_TEMP_FILE" ]; then
    for temp_file in /sys/class/hwmon/hwmon*/temp1_input; do
        if [ -f "$temp_file" ]; then
            hwmon_dir=$(dirname "$temp_file")
            name=""
            [ -f "$hwmon_dir/name" ] && name=$(cat "$hwmon_dir/name" 2>/dev/null)
            if [ "$name" != "amdgpu" ] && [ "$name" != "nvme" ]; then
                CPU_TEMP_FILE="$temp_file"
                break
            fi
        fi
    done
fi

if [ -n "$CPU_TEMP_FILE" ] && [ -f "$CPU_TEMP_FILE" ]; then
    CPU_TEMP=$(( $(cat "$CPU_TEMP_FILE" 2>/dev/null || echo 0) / 1000 ))
fi

# GPU utilization and temperature (AMDGPU dynamic card lookup)
GPU_UTIL=0
GPU_TEMP=0

for card_dev in /sys/class/drm/card*/device; do
    if [ -f "$card_dev/gpu_busy_percent" ]; then
        GPU_UTIL=$(cat "$card_dev/gpu_busy_percent" 2>/dev/null || echo 0)
    fi
    for temp_file in "$card_dev"/hwmon/hwmon*/temp1_input; do
        if [ -f "$temp_file" ]; then
            GPU_TEMP=$(( $(cat "$temp_file" 2>/dev/null || echo 0) / 1000 ))
            break
        fi
    done
done

TEXT="󰻠 ${CPU_UTIL}% (${CPU_TEMP}°C)  󰾲 ${GPU_UTIL}% (${GPU_TEMP}°C)"
TOOLTIP=$(printf "System Status:\n\nCPU Usage: %s%%\nCPU Temp: %s°C\n\nGPU Usage: %s%%\nGPU Temp: %s°C" "$CPU_UTIL" "$CPU_TEMP" "$GPU_UTIL" "$GPU_TEMP")

jq -n -c --arg text "$TEXT" --arg tooltip "$TOOLTIP" '{text: $text, tooltip: $tooltip}'


