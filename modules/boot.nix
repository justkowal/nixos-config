{ ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.timeout = 0;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot/efi";
  boot.supportedFilesystems = [ "bcachefs" ];

  boot.initrd.systemd.enable = true;
  boot.initrd.compressor = "lz4";
  boot.initrd.includeDefaultModules = false;
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;

  # RAM-backed /tmp for high-speed scratch and build I/O
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "75%";

  # Avoid slow early boot VFAT write syncs
  systemd.services.systemd-boot-random-seed.enable = false;
}
