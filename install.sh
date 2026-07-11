#!/usr/bin/env bash
#
# NixOS Premium Interactive Installer
# Pre-configures target disk (partitioning, formatting, mounting) and installs the custom flake profile.
#
set -euo pipefail

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

clear
echo -e "${PURPLE}================================================================${NC}"
echo -e "${CYAN}        NixOS Premium Interactive Installer & Setup         ${NC}"
echo -e "${PURPLE}================================================================${NC}"
echo ""

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This installer must be run with root privileges (sudo).${NC}"
  exit 1
fi

# Step 1: Disk selection
echo -e "${YELLOW}[1/5] Identifying target storage disk...${NC}"
lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -v "loop"
echo ""

read -p "Enter target disk name for NixOS (e.g., nvme0n1, sda): " DISK
DISK_PATH="/dev/$DISK"

if [ ! -b "$DISK_PATH" ]; then
  echo -e "${RED}Error: Device $DISK_PATH is not a valid block device.${NC}"
  exit 1
fi

echo -e "\nTarget disk path: ${GREEN}$DISK_PATH${NC}"
echo -e "${RED}WARNING: Partitioning $DISK_PATH will permanently erase all data!${NC}"
read -p "Are you sure? Type 'CONFIRM' to partition this drive: " CONFIRM_PART
if [ "$CONFIRM_PART" != "CONFIRM" ]; then
  echo -e "${RED}Installation aborted by user.${NC}"
  exit 1
fi

# Step 2: Partitioning
echo -e "\n${YELLOW}[2/5] Partitioning disk $DISK_PATH (UEFI GPT layout)...${NC}"
sgdisk --zap-all "$DISK_PATH"

# Partition 1: EFI Boot (512M, type EF00)
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"boot" "$DISK_PATH"

# Partition 2: Root Filesystem (Remaining space, type 8300)
sgdisk -n 2:0:0 -t 2:8300 -c 2:"nixos" "$DISK_PATH"

# Reload partition tables
udevadm settle

# Detect partition naming scheme (e.g., nvme0n1p1 vs sda1)
if [[ "$DISK" =~ "nvme" || "$DISK" =~ "mmcblk" ]]; then
  EFI_PART="${DISK_PATH}p1"
  ROOT_PART="${DISK_PATH}p2"
else
  EFI_PART="${DISK_PATH}1"
  ROOT_PART="${DISK_PATH}2"
fi

# Step 3: Formatting
echo -e "\n${YELLOW}[3/5] Formatting partitions...${NC}"
echo -e "${CYAN}Formatting EFI partition ($EFI_PART) as FAT32 with label 'boot'...${NC}"
mkfs.fat -F 32 -n "boot" "$EFI_PART"

echo -e "${CYAN}Formatting Root partition ($ROOT_PART) as Bcachefs with label 'nixos'...${NC}"
mkfs.bcachefs --compression=zstd --label=nixos "$ROOT_PART"

# Step 4: Mounting filesystems
echo -e "\n${YELLOW}[4/5] Mounting new filesystems to /mnt...${NC}"
mkdir -p /mnt
mount -o compression=zstd,noatime "$ROOT_PART" /mnt

mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

echo -e "${GREEN}Filesystems successfully mounted at /mnt:${NC}"
df -h | grep "/mnt"

# Step 5: Transferring configuration
echo -e "\n${YELLOW}[5/5] Deploying NixOS configuration...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p /mnt/etc/nixos

echo -e "Copying config files from $SCRIPT_DIR to /mnt/etc/nixos..."
cp -r "$SCRIPT_DIR/"* /mnt/etc/nixos/

# Remove the install script from the target disk configuration directory to keep it clean
rm -f /mnt/etc/nixos/install.sh

echo -e "\n${GREEN}Preconfiguration successful!${NC}"
echo -e "Your modular system files are staged at ${CYAN}/mnt/etc/nixos${NC}."
echo -e "To compile your custom LLVM ThinLTO kernel and install NixOS, run:"
echo -e "${PURPLE}nixos-install --flake /mnt/etc/nixos#desktop${NC}"
echo ""

read -p "Would you like to run the installation build now? (y/n): " RUN_INSTALL
if [[ "$RUN_INSTALL" =~ ^[Yy]$ ]]; then
  echo -e "\n${GREEN}Launching nixos-install...${NC}"
  nixos-install --flake /mnt/etc/nixos#desktop
else
  echo -e "\n${YELLOW}Setup completed. You can trigger the build manually when ready by running:${NC}"
  echo -e "${CYAN}sudo nixos-install --flake /mnt/etc/nixos#desktop${NC}"
fi
