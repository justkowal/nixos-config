{ pkgs, ... }:

{
  # Generic boot settings shared across all hosts.
  # Bootloader-specific config (systemd-boot vs GRUB) lives in each host's configuration.nix.
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot/efi";
  boot.supportedFilesystems = [ "bcachefs" ];

  boot.initrd.systemd.enable = true;
  boot.initrd.compressor = "${pkgs.lz4.out}/bin/lz4 -l -9";
  boot.initrd.includeDefaultModules = false;
  boot.initrd.availableKernelModules = [ "i8042" "atkbd" ];
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;

  # RAM-backed /tmp for high-speed scratch and build I/O
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "75%";
}
