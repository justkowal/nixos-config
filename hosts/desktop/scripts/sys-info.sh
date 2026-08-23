#!/usr/bin/env bash
# Unified CPU + GPU sensor monitor for Waybar (JSON output)

# CPU usage over 0.5 seconds
read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
prev_idle=$((idle + iowait))
prev_non_idle=$((user + nice + system + irq + softirq + steal))
prev_total=$((prev_idle + prev_non_idle))

sleep 0.5

read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
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

# CPU temperature (k10temp)
CPU_TEMP_FILE=$(find /sys/class/hwmon/ -name "temp1_input" | grep -v "amdgpu" | grep -v "nvme" | head -n 1)
CPU_TEMP_DIR=$(grep -l "k10temp" /sys/class/hwmon/hwmon*/name 2>/dev/null | awk -F/ '{print "/sys/class/hwmon/" $5 "/temp1_input"}')
if [ -f "$CPU_TEMP_DIR" ]; then
    CPU_TEMP_FILE="$CPU_TEMP_DIR"
fi

CPU_TEMP=0
if [ -f "$CPU_TEMP_FILE" ]; then
    CPU_TEMP=$(( $(cat "$CPU_TEMP_FILE") / 1000 ))
fi

# GPU utilization and temperature (AMDGPU)
GPU_BUSY_PATH="/sys/class/drm/card1/device/gpu_busy_percent"
GPU_TEMP_FILE=$(find /sys/class/drm/card1/device/hwmon/ -name "temp1_input" 2>/dev/null | head -n 1)

GPU_UTIL=0
if [ -f "$GPU_BUSY_PATH" ]; then
    GPU_UTIL=$(cat "$GPU_BUSY_PATH")
fi

GPU_TEMP=0
if [ -f "$GPU_TEMP_FILE" ]; then
    GPU_TEMP=$(( $(cat "$GPU_TEMP_FILE") / 1000 ))
fi

TEXT=" ${CPU_UTIL}% (${CPU_TEMP}°C)  󰾲 ${GPU_UTIL}% (${GPU_TEMP}°C)"
TOOLTIP=$(printf "System Status:\n\nCPU Usage: %s%%\nCPU Temp: %s°C\n\nGPU Usage: %s%%\nGPU Temp: %s°C" "$CPU_UTIL" "$CPU_TEMP" "$GPU_UTIL" "$GPU_TEMP")

jq -n -c --arg text "$TEXT" --arg tooltip "$TOOLTIP" '{text: $text, tooltip: $tooltip}'
