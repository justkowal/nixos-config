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
