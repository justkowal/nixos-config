{
  config,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../../modules/overlays.nix
    ../../modules/boot.nix
    ../../modules/locale.nix
    ../../modules/user.nix
    ../../modules/nix-settings.nix
    ../../modules/services.nix
    ../../modules/security.nix
    ../../modules/kernel-laptop.nix
    ../../modules/graphical.nix
    ../../modules/shell.nix
    ../../modules/apps.nix
    ../../modules/systemd-minimal.nix
    ../../modules/laptop.nix
    ../../modules/networking.nix
  ];

  home-manager.backupFileExtension = "backup";
  home-manager.extraSpecialArgs = {
    laptop = true;
  };

  hardware.enableRedistributableFirmware = true;
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;
  services.fwupd.enable = true;

  # Laptop Battery Power Management & Thermal Control
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      RUNTIME_PM_ON_AC = "auto";
      RUNTIME_PM_ON_BAT = "auto";
      SATA_LINKPWR_ON_BAT = "min_power";
      WIFI_PWR_ON_AC = "off";
      WIFI_PWR_ON_BAT = "on";
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
  networking.hostName = "thinkpad-t14s-gen1-amd";

  # Networking
  networking.networkmanager.enable = true;

  # Define user account
  users.users.justkowal = {
    isNormalUser = true;
    description = "justkowal";
    extraGroups = ["networkmanager" "wheel" "video" "render" "docker" "input"];
  };

  # NixOS State Version
  system.stateVersion = "26.05";
}
