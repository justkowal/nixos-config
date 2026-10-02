{
  config,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../../modules/desktop.nix
    ../../modules/shell.nix
    ../../modules/apps.nix
    ../../modules/systemd-minimal.nix
    ../../modules/performance.nix
    ../../modules/networking.nix
    ../../modules/overlays.nix
  ];

  home-manager.backupFileExtension = "backup";

  # Bootloader setup (UEFI / BIOS compatibility for QEMU / KVM / VirtualBox)
  boot.loader.systemd-boot.enable = true;
  boot.loader.timeout = 0;
  boot.loader.efi.canTouchEfiVariables = true;
  systemd.services.systemd-boot-random-seed.enable = false;

  # QEMU / KVM / VirtualBox Guest Integration Agents & Display Scaling
  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true; # Clipboard sharing & auto display resizing

  # Hostname
  networking.hostName = "nixos-vm";

  # Networking
  networking.networkmanager.enable = true;

  # Set time zone & locale
  time.timeZone = "Europe/Warsaw";
  i18n.defaultLocale = "en_US.UTF-8";

  # Define user account
  users.users.justkowal = {
    isNormalUser = true;
    description = "justkowal";
    extraGroups = ["networkmanager" "wheel" "video" "render" "docker"];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # High-speed Nix binary caches & HTTP/2 download multiplexing
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    max-jobs = "auto";
    cores = 0;
    auto-optimise-store = true;
    connect-timeout = 5;
    substituters = [
      "https://cache.nixos.org"
      "https://hyprland.cachix.org"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  # NH CLI Helper
  programs.nh = {
    enable = true;
    clean.enable = true;
    clean.extraArgs = "--keep 5";
    flake = "/etc/nixos";
  };

  # Enable nix-ld & dconf
  programs.nix-ld.enable = true;
  programs.dconf.enable = true;

  # CPU Frequency Governor for VM
  powerManagement.cpuFreqGovernor = "performance";

  # NixOS State Version
  system.stateVersion = "26.05";
}
