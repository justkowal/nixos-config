#!/usr/bin/env bash
set -e

# Interactive TUI Wizard using Charm Gum
if command -v gum &> /dev/null; then
  gum style --border double --margin "1 2" --padding "1 3" --border-foreground 212 \
    "Custom NixOS Multi-Host Installer Wizard" \
    "Deploy Desktop, Laptop, or VM target with preconfigured userland"

  # Automatic Hardware Detection
  VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
  HAS_BATTERY=$(ls /sys/class/power_supply/BAT* 2>/dev/null | head -n 1)

  if [ "$VIRT_TYPE" != "none" ]; then
    DEFAULT_HOST="vm"
    AUTO_REASON="Virtual Machine detected ($VIRT_TYPE)"
  elif [ -n "$HAS_BATTERY" ]; then
    DEFAULT_HOST="laptop"
    AUTO_REASON="Laptop battery detected"
  else
    DEFAULT_HOST="desktop"
    AUTO_REASON="Bare-metal desktop hardware detected"
  fi

  gum style --foreground 212 "Hardware Detection: $AUTO_REASON (Auto-focused profile: '$DEFAULT_HOST')"

  HOST_CHOICE=$(gum choose --header "Select NixOS Target Host Profile:" --selected "$DEFAULT_HOST" "desktop" "laptop" "vm")
  TARGET_DISK=$(gum input --placeholder "/dev/nvme0n1 or /dev/sda" --header "Enter Target Disk Device Path:")

  if [ -z "$TARGET_DISK" ] || [ ! -b "$TARGET_DISK" ]; then
    gum style --foreground 196 "Invalid disk device '$TARGET_DISK'. Aborting installation."
    exit 1
  fi

  gum confirm "DANGER: This will format $TARGET_DISK and install '$HOST_CHOICE'. Are you sure?" || exit 0

  echo ""
  echo "[1/3] Partitioning target disk $TARGET_DISK..."
  parted -s "$TARGET_DISK" mklabel gpt
  parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 512MiB
  parted -s "$TARGET_DISK" set 1 esp on
  parted -s "$TARGET_DISK" mkpart primary 512MiB 100%

  if [[ "$TARGET_DISK" == *"nvme"* ]]; then
    BOOT_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
  else
    BOOT_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
  fi

  echo "[2/3] Formatting file systems (vfat boot + ext4 root)..."
  mkfs.vfat -F32 -n boot "$BOOT_PART"
  mkfs.ext4 -F -L nixos "$ROOT_PART"

  echo "[3/3] Mounting filesystems and triggering NixOS Installation ($HOST_CHOICE)..."
  mount /dev/disk/by-label/nixos /mnt
  mkdir -p /mnt/boot
  mount /dev/disk/by-label/boot /mnt/boot

  nixos-install --flake "/etc/nixos#$HOST_CHOICE" --no-root-passwd

  gum style --foreground 82 --border normal --padding "1 2" \
    "SUCCESS! NixOS '$HOST_CHOICE' profile installed successfully." \
    "Reboot system and remove installation media."
else
  echo "TUI tool 'gum' not found. Running fallback CLI mode..."
  echo "Available profiles: desktop, laptop, vm"
  read -p "Target profile: " HOST_CHOICE
  read -p "Target disk (/dev/nvme0n1): " TARGET_DISK
  nixos-install --flake "/etc/nixos#$HOST_CHOICE"
fi
