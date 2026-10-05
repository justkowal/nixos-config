#!/usr/bin/env bash
# Intelligent NixOS distributed build manager for Laptop
# If Desktop builder is offline, prompts to wake via Pi with a 5-second default timeout
set -euo pipefail

CURR_HOST=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "")
if [[ "$CURR_HOST" != *"laptop"* && "$CURR_HOST" != *"thinkpad"* && "$CURR_HOST" != *"t14s"* ]]; then
  if [ $# -eq 0 ]; then
    if command -v nh >/dev/null 2>&1; then
      exec nh os switch /etc/nixos
    else
      exec nixos-rebuild switch --flake /etc/nixos
    fi
  else
    exec "$@"
  fi
fi

TARGET_HOST="nixos-desktop.lab"
TARGET_MAC="10:ff:e0:40:7d:6e"
TIMEOUT_SECS=5

# Check if running interactively or have access to controlling terminal (/dev/tty)
IS_INTERACTIVE=false
TTY_OUT="/dev/stderr"
TTY_IN="/dev/stdin"

if [ -r /dev/tty ] && [ -w /dev/tty ]; then
  IS_INTERACTIVE=true
  TTY_OUT="/dev/tty"
  TTY_IN="/dev/tty"
elif [ -t 0 ]; then
  IS_INTERACTIVE=true
fi

# Function to check if desktop SSH port is open
is_desktop_online() {
  nc -z -w 1 "$TARGET_HOST" 22 2>/dev/null || ping -c 1 -W 1 "$TARGET_HOST" >/dev/null 2>&1
}

USE_REMOTE=true

if ! is_desktop_online; then
  if [ "$IS_INTERACTIVE" = true ]; then
    printf "\n󰞷 Desktop builder (%s) is powered off.\n" "$TARGET_HOST" > "$TTY_OUT"
    printf "󱐋 Wake Desktop via Pi for 16-core distributed builds? [y/N] (skipping in %ds): " "$TIMEOUT_SECS" > "$TTY_OUT"

    # Read with 5 second timeout from controlling terminal
    RESPONSE=""
    read -t "$TIMEOUT_SECS" -n 1 RESPONSE < "$TTY_IN" || true
    printf "\n" > "$TTY_OUT"

    if [[ "$RESPONSE" =~ ^[Yy]$ ]]; then
      printf "󱐋 Sending Wake signal via Pi (local Ethernet)...\n" > "$TTY_OUT"
      curl -s -X POST http://nixos-rpi4.lab:9100/hooks/wake-worker >/dev/null 2>&1 || \
        ssh -o ConnectTimeout=3 justkowal@nixos-rpi4.lab wake-worker >/dev/null 2>&1 || true
      wakeonlan "$TARGET_MAC" >/dev/null 2>&1 || true

      printf "󱍷 Waiting for Desktop to boot (Scale-to-Zero)...\n" > "$TTY_OUT"
      START_TIME=$(date +%s)
      BOOTED=false
      while [ $(( $(date +%s) - START_TIME )) -lt 90 ]; do
        ELAPSED=$(( $(date +%s) - START_TIME ))
        if is_desktop_online; then
          BOOTED=true
          printf "\n󰄲 Desktop is online! Handing off distributed build...\n\n" > "$TTY_OUT"
          break
        fi
        printf "   Booting Desktop... (%ds elapsed)\r" "$ELAPSED" > "$TTY_OUT"
        sleep 2
      done

      if [ "$BOOTED" = false ]; then
        printf "\n󰀦 Timed out waiting for Desktop. Falling back to local build...\n\n" > "$TTY_OUT"
        USE_REMOTE=false
      fi
    else
      printf "󰅒 Distributed builds skipped — continuing with local CPU cores.\n\n" > "$TTY_OUT"
      USE_REMOTE=false
    fi
  else
    # Non-interactive: immediately skip remote builder
    USE_REMOTE=false
  fi
fi

# Execute the requested build command (defaults to `nh os switch /etc/nixos`)
BUILD_ARGS=("$@")
if [ ${#BUILD_ARGS[@]} -eq 0 ]; then
  if command -v nh >/dev/null 2>&1; then
    BUILD_ARGS=("nh" "os" "switch" "/etc/nixos")
  else
    BUILD_ARGS=("nixos-rebuild" "switch" "--flake" "/etc/nixos#thinkpad-t14s-gen1-amd")
  fi
fi

if [ "$USE_REMOTE" = false ]; then
  # Inject builder disable flag
  if [[ "${BUILD_ARGS[0]}" == *"nh"* ]]; then
    exec "${BUILD_ARGS[@]}" --builders ""
  elif [[ "${BUILD_ARGS[0]}" == *"nixos-rebuild"* ]]; then
    exec "${BUILD_ARGS[@]}" --option builders ""
  else
    exec "${BUILD_ARGS[@]}" --option builders ""
  fi
else
  exec "${BUILD_ARGS[@]}"
fi
