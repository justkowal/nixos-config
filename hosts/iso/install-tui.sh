#!/usr/bin/env bash
set -e

# Interactive TUI Wizard using Charm Gum
if command -v gum &> /dev/null; then
  gum style --border double --margin "1 2" --padding "1 3" --border-foreground 212 \
    "Custom NixOS Laptop Prebuilt Installer" \
    "Deploy the laptop target from prebuilt store paths"

  # Automatic Hardware Detection
  HAS_BATTERY=$(ls /sys/class/power_supply/BAT* 2>/dev/null | head -n 1)

  if [ -n "$HAS_BATTERY" ]; then
    DEFAULT_HOST="laptop"
    AUTO_REASON="Laptop battery detected"
  else
    DEFAULT_HOST="laptop"
    AUTO_REASON="Laptop prebuilt profile selected"
  fi

  gum style --foreground 212 "Hardware Detection: $AUTO_REASON (Auto-focused profile: '$DEFAULT_HOST')"

  TARGET_DISK=$(gum input --placeholder "/dev/nvme0n1 or /dev/sda" --header "Enter Target Disk Device Path:")

  if [ -z "$TARGET_DISK" ] || [ ! -b "$TARGET_DISK" ]; then
    gum style --foreground 196 "Invalid disk device '$TARGET_DISK'. Aborting installation."
    exit 1
  fi

  gum confirm "DANGER: This will format $TARGET_DISK and install the laptop profile. Are you sure?" || exit 0

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

  echo "[3/3] Mounting filesystems and triggering NixOS Installation (laptop)..."
  mount /dev/disk/by-label/nixos /mnt
  mkdir -p /mnt/boot
  mount /dev/disk/by-label/boot /mnt/boot

  nixos-install --system /etc/laptop-system --no-root-passwd

  gum style --foreground 82 --border normal --padding "1 2" \
    "SUCCESS! NixOS laptop profile installed successfully." \
    "Reboot system and remove installation media."
else
  echo "TUI tool 'gum' not found. Running fallback CLI mode..."
  read -p "Target disk (/dev/nvme0n1): " TARGET_DISK
  nixos-install --system /etc/laptop-system --no-root-passwd
fi
