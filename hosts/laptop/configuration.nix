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
  ];

  home-manager.backupFileExtension = "backup";

  # Bootloader setup (UEFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.timeout = 0;
  boot.loader.efi.canTouchEfiVariables = true;

  # Laptop Battery Power Management & Thermal Control
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
    };
  };

  # Touchpad support (Libinput)
  services.libinput = {
    enable = true;
    touchpad = {
      tapping = true;
      naturalScrolling = true;
      scrollMethod = "twofinger";
    };
  };

  # Backlight brightness control without root privileges
  hardware.acpilight.enable = true;
  services.upower.enable = true;

  # Hostname
  networking.hostName = "nixos-laptop";

  # Networking
  networking.networkmanager.enable = true;

  # Set time zone & locale
  time.timeZone = "Europe/Warsaw";
  i18n.defaultLocale = "en_US.UTF-8";

  # Define user account
  users.users.justkowal = {
    isNormalUser = true;
    description = "justkowal";
    extraGroups = ["networkmanager" "wheel" "video" "render" "docker" "input"];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # High-speed Nix binary caches
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

  # NixOS State Version
  system.stateVersion = "26.05";
}
