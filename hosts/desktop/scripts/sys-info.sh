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

# Memory usage from /proc/meminfo
MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_AVAIL=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$MEM_TOTAL" -gt 0 ]; then
    MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
    MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
    MEM_USED_GB=$(awk -v u="$MEM_USED" 'BEGIN {printf "%.1f", u / 1048576}')
    MEM_TOTAL_GB=$(awk -v t="$MEM_TOTAL" 'BEGIN {printf "%.1f", t / 1048576}')
else
    MEM_PCT=0
    MEM_USED_GB="0"
    MEM_TOTAL_GB="0"
fi

# Dynamic GPU model resolution
GPU_NAME=""
if command -v lspci >/dev/null 2>&1; then
    vga_line=$(lspci -d ::0300 2>/dev/null | head -n1)
    [ -z "$vga_line" ] && vga_line=$(lspci 2>/dev/null | grep -E "VGA|3D|Display" | head -n1)
    if [ -n "$vga_line" ]; then
        cleaned=$(echo "$vga_line" | sed -E "
            s/.*controller: //;
            s/.*controller \[[0-9a-fA-F]+\]: //;
            s/Advanced Micro Devices, Inc\. \[[^]]*\] //g;
            s/NVIDIA Corporation //g;
            s/Intel Corporation //g;
            s/\(rev [0-9a-fA-F]+\)//g;
            s/\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]//g;
        ")
        if echo "$cleaned" | grep -qi "6700"; then
            GPU_NAME="Radeon RX 6700 XT"
        elif echo "$cleaned" | grep -qi "Vega"; then
            GPU_NAME="Radeon Vega Graphics"
        elif echo "$cleaned" | grep -qi "Renoir"; then
            GPU_NAME="Radeon Graphics (Renoir)"
        else
            GPU_NAME=$(echo "$cleaned" | sed -E "s/.*\[([^]]+)\].*/\1/" | sed "s/^[ \t]*//;s/[ \t]*$//")
        fi
    fi
fi

if [ -z "$GPU_NAME" ] || [ "$GPU_NAME" = "GPU" ]; then
    for card_dev in /sys/class/drm/card*/device; do
        if [ -f "$card_dev/device" ]; then
            dev_id=$(cat "$card_dev/device" 2>/dev/null || true)
            if [ "$dev_id" = "0x73df" ]; then
                GPU_NAME="Radeon RX 6700 XT"
                break
            elif [ "$dev_id" = "0x1636" ] || [ "$dev_id" = "0x1638" ]; then
                GPU_NAME="Radeon Vega Graphics"
                break
            fi
        fi
    done
fi

if [ -z "$GPU_NAME" ]; then
    curr_host=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "")
    if [[ "$curr_host" == *"laptop"* || "$curr_host" == *"thinkpad"* || "$curr_host" == *"t14s"* ]]; then
        GPU_NAME="Radeon Vega Graphics"
    else
        GPU_NAME="Radeon RX 6700 XT"
    fi
fi

# Storage usage for main filesystem (/nix or /)
DISK_INFO=$(df -h /nix / 2>/dev/null | awk 'NR==2 {print $3, $2, $5}')
DISK_USED=$(echo "$DISK_INFO" | awk '{print $1}')
DISK_TOTAL=$(echo "$DISK_INFO" | awk '{print $2}')
DISK_PCT=$(echo "$DISK_INFO" | awk '{print $3}')

# System load average
LOAD_AVG=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "0.0 0.0 0.0")

if [[ "$curr_host" == *"laptop"* || "$curr_host" == *"thinkpad"* || "$curr_host" == *"t14s"* ]]; then
  TEXT="󰻠 ${CPU_TEMP}°"
else
  TEXT="󰻠 ${CPU_TEMP}° 󰾲 ${GPU_TEMP}°"
fi
TOOLTIP=$(cat <<EOF
── 󰍛 System Hardware Telemetry ─────────────────
󰻠 Processor: ${CPU_UTIL}% utilized (${CPU_TEMP}°C)
  └─ Load Average: ${LOAD_AVG}
󰾲 Graphics: ${GPU_NAME} · ${GPU_UTIL}% utilized (${GPU_TEMP}°C)
󰍛 Memory: ${MEM_PCT}% utilized (${MEM_USED_GB} / ${MEM_TOTAL_GB} GiB)
󰋊 Storage: ${DISK_PCT} utilized (${DISK_USED} / ${DISK_TOTAL})
─────────────────────────────────────────────────
Click: Open Control Center (Super+C)
EOF
)

jq -n -c --arg text "$TEXT" --arg tooltip "$TOOLTIP" '{text: $text, tooltip: $tooltip}'


