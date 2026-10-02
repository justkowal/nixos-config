#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# ThinkPad T14s Gen 1 AMD - In-Place LUKS2 + TPM2 Encryption Automation Script
# Must be executed from a NixOS Live USB environment as root!
# ==============================================================================

PART_UUID="31a0a789-2f9e-499c-91a6-76bc90aef8b9"
TARGET_DEV="/dev/disk/by-partuuid/${PART_UUID}"
REAL_DEV=$(readlink -f "$TARGET_DEV")
BOOT_DEV="/dev/disk/by-label/boot"
MOUNT_DIR="/mnt"

echo "=== ThinkPad T14s In-Place LUKS2 + TPM2 Encryption ==="
echo "Target Partition: $REAL_DEV (PARTUUID: $PART_UUID)"
echo ""

if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)." >&2
  exit 1
fi

if [ ! -b "$REAL_DEV" ]; then
  echo "Error: Target partition $TARGET_DEV ($REAL_DEV) not found!" >&2
  exit 1
fi

# Ensure partition is not mounted
if grep -qs "$REAL_DEV" /proc/mounts; then
  echo "Unmounting $REAL_DEV..."
  umount "$REAL_DEV" || true
fi

echo "[1/7] Checking Btrfs filesystem integrity..."
btrfs check "$REAL_DEV"

echo "[2/7] Mounting to shrink Btrfs filesystem by 32MB for LUKS2 header..."
mkdir -p "$MOUNT_DIR"
mount "$REAL_DEV" "$MOUNT_DIR"
btrfs filesystem resize -32M "$MOUNT_DIR"
umount "$MOUNT_DIR"

echo "[3/7] Re-encrypting partition in-place with LUKS2..."
echo "Please enter a strong MASTER RECOVERY PASSPHRASE when prompted."
echo "(This is your emergency backup if the TPM chip or motherboard is ever replaced)"
echo ""
cryptsetup reencrypt --encrypt --reduce-device-size 32M "$REAL_DEV"

echo "[4/7] Opening encrypted container as 'cryptroot'..."
cryptsetup open "$REAL_DEV" cryptroot

echo "[5/7] Resizing Btrfs filesystem to fill encrypted container..."
mount /dev/mapper/cryptroot "$MOUNT_DIR"
btrfs filesystem resize max "$MOUNT_DIR"

echo "[6/7] Enrolling TPM 2.0 (PCR 0+2+7) for passwordless auto-unlock..."
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+2+7 "$REAL_DEV"

echo "[7/7] Updating NixOS hardware configuration and rebuilding bootloader..."
HW_CONFIG="$MOUNT_DIR/etc/nixos/hosts/laptop/hardware-configuration.nix"

if [ -f "$HW_CONFIG" ]; then
  # Ensure TPM modules and LUKS configuration are present
  cat << 'EOF' > "$HW_CONFIG"
# Laptop hardware-configuration (LUKS2 + TPM2 Encrypted)
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = ["nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" "tpm_crb" "tpm_tis"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-amd" "thinkpad_acpi"];
  boot.extraModulePackages = [];

  boot.initrd.systemd.enable = true;
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-partuuid/31a0a789-2f9e-499c-91a6-76bc90aef8b9";
    crypttabExtraOpts = [ "tpm2-device=auto" "tpm2-measure-pcr=yes" ];
    allowDiscards = true;
  };

  fileSystems."/" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "compress=zstd" "noatime" "discard=async" ];
  };

  fileSystems."/boot/efi" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
  };

  swapDevices = [];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
EOF
fi

# Mount boot/efi for bootloader rebuild
mkdir -p "$MOUNT_DIR/boot/efi"
mount "$BOOT_DEV" "$MOUNT_DIR/boot/efi"

echo "Rebuilding NixOS initrd and bootloader with LUKS + TPM2..."
nixos-enter --root "$MOUNT_DIR" -c "nixos-rebuild boot --flake /etc/nixos#thinkpad-t14s-gen1-amd"

echo "Unmounting filesystems..."
umount "$MOUNT_DIR/boot/efi"
umount "$MOUNT_DIR"
cryptsetup close cryptroot

echo ""
echo "=================================================================="
echo " SUCCESS! Your ThinkPad disk is now fully encrypted with LUKS2    "
echo " and sealed by TPM 2.0.                                           "
echo " Reboot now and enjoy passwordless, measured, tamper-proof boot!  "
echo "=================================================================="
