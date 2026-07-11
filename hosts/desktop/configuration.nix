{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/kernel.nix
    ../../modules/desktop.nix
    ../../modules/shell.nix
    ../../modules/apps.nix
    ../../modules/systemd-minimal.nix
    ../../modules/performance.nix
    ../../modules/hardware.nix
    ../../modules/networking.nix
  ];

  # Bootloader setup (UEFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = [ "bcachefs" ];

  # Hostname
  networking.hostName = "nixos-desktop";

  # Networking
  networking.networkmanager.enable = true;

  # Set time zone
  time.timeZone = "Europe/Warsaw"; # Based on user's timezone offset (+02:00)

  # Select internationalisation properties
  i18n.defaultLocale = "pl_PL.UTF-8"; # Based on Polish folders ("Jasełka", "SieniuStrona") in home directories
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "pl_PL.UTF-8";
    LC_IDENTIFICATION = "pl_PL.UTF-8";
    LC_MEASUREMENT = "pl_PL.UTF-8";
    LC_MONETARY = "pl_PL.UTF-8";
    LC_NAME = "pl_PL.UTF-8";
    LC_NUMERIC = "pl_PL.UTF-8";
    LC_PAPER = "pl_PL.UTF-8";
    LC_TELEPHONE = "pl_PL.UTF-8";
    LC_TIME = "pl_PL.UTF-8";
  };

  # Configure console keymap
  console.keyMap = "pl2";

  # Define a user account
  users.users.justkowal = {
    isNormalUser = true;
    description = "justkowal";
    extraGroups = [ "networkmanager" "wheel" "video" "render" "docker" ];
  };

  # Allow unfree packages (needed for Steam, VS Code, etc.)
  nixpkgs.config.allowUnfree = true;

  # Experimental features (Flakes & Nix profile)
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Optimize Nix compilation resource utilization (especially for LTO kernel build)
  nix.settings.max-jobs = "auto";
  nix.settings.cores = 0; # Use all CPU threads

  # Auto-optimise store (deduplicates identical files in the store to save space)
  nix.settings.auto-optimise-store = true;

  # Automatic Garbage Collection (keeps system clean by deleting older builds)
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Enable nix-ld to run pre-compiled non-Nix binaries seamlessly
  programs.nix-ld.enable = true;

  # Enable Docker container virtualization service
  virtualisation.docker.enable = true;

  # Enable the system-wide SSH agent for credential caching
  programs.ssh.startAgent = true;

  # Basic system packages (core tools)
  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    vim
    pciutils
    usbutils
  ];

  # CPU Frequency Governor (Force performance mode for maximum responsiveness on desktop)
  powerManagement.cpuFreqGovernor = "performance";

  # NixOS State Version
  system.stateVersion = "26.05";
}
