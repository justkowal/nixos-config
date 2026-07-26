{
  config,
  pkgs,
  inputs,
  ...
}: {
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
    ../../modules/vpn.nix
    ../../modules/ai.nix
  ];

  home-manager.backupFileExtension = "backup";

  # Bootloader setup (UEFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.timeout = 0;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot/efi";
  boot.supportedFilesystems = ["bcachefs"];

  # Stage 1 Initrd and Kernel Logging Optimizations
  boot.initrd.systemd.enable = true;
  boot.initrd.compressor = "zstd";
  boot.initrd.includeDefaultModules = false;
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;

  # Disable NetworkManager wait online service to prevent boot delays
  systemd.services.NetworkManager-wait-online.enable = false;

  # Weekly Bcachefs Filesystem Scrub / Integrity Check Timer
  systemd.services.bcachefs-scrub = {
    description = "Weekly Bcachefs Filesystem Scrub & Check";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bcachefs-tools}/bin/bcachefs fsck /dev/disk/by-uuid/91169176-2eea-4719-8327-2e0bbc3cc0c1";
    };
  };
  systemd.timers.bcachefs-scrub = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };

  # Automated Hourly AI File Organizer Service & Timer
  systemd.user.services.ai-organize = {
    description = "Hourly AI File Organizer Daemon";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 /home/justkowal/.config/hypr/scripts/ai_organize.py /home/justkowal/Downloads";
    };
  };
  systemd.user.timers.ai-organize = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };

  # Disable ESP random seed updates to avoid slow early boot VFAT write syncs
  systemd.services.systemd-boot-random-seed.enable = false;

  # Hostname
  networking.hostName = "nixos-desktop";

  # Networking
  networking.networkmanager.enable = true;

  # Set time zone
  time.timeZone = "Europe/Warsaw"; # Based on user's timezone offset (+02:00)

  # Select internationalisation properties
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  i18n.supportedLocales = [ "en_US.UTF-8/UTF-8" "pl_PL.UTF-8/UTF-8" ];

  # Configure console keymap
  console.keyMap = "pl2";

  # Define a user account
  users.users.justkowal = {
    isNormalUser = true;
    description = "justkowal";
    extraGroups = ["networkmanager" "wheel" "video" "render" "docker"];
  };

  # Allow unfree packages (needed for Steam, VS Code, etc.)
  nixpkgs.config.allowUnfree = true;

  # Workaround for minizip-ng test failure and custom millennium packages definition to inherit overlays
  nixpkgs.overlays = [
    (final: prev: {
      minizip-ng = prev.minizip-ng.overrideAttrs (oldAttrs: {
        doCheck = false;
      });

      millennium = final.callPackage "${inputs.millennium.outPath}/millennium.nix" {
        millennium-src = inputs.millennium.inputs.millennium-src;
      };

      millennium-steam = final.callPackage "${inputs.millennium.outPath}/steam.nix" {
        inherit (final) millennium;
      };
    })
  ];

  # XDG MIME associations (Default Applications)
  xdg.mime.enable = true;
  xdg.mime.defaultApplications = {
    "application/pdf" = [ "org.pwmt.zathura.desktop" ];
    "image/png" = [ "org.gnome.Loupe.desktop" ];
    "image/jpeg" = [ "org.gnome.Loupe.desktop" ];
    "image/webp" = [ "org.gnome.Loupe.desktop" ];
    "image/gif" = [ "org.gnome.Loupe.desktop" ];
    "image/svg+xml" = [ "org.gnome.Loupe.desktop" ];
    "video/mp4" = [ "vlc.desktop" ];
    "video/x-matroska" = [ "vlc.desktop" ];
    "video/webm" = [ "vlc.desktop" ];
    "video/quicktime" = [ "vlc.desktop" ];
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = [ "libreoffice-writer.desktop" ];
    "application/msword" = [ "libreoffice-writer.desktop" ];
    "application/vnd.oasis.opendocument.text" = [ "libreoffice-writer.desktop" ];
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = [ "libreoffice-calc.desktop" ];
    "application/vnd.ms-excel" = [ "libreoffice-calc.desktop" ];
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" = [ "libreoffice-impress.desktop" ];
    "x-scheme-handler/http" = [ "firefox.desktop" ];
    "x-scheme-handler/https" = [ "firefox.desktop" ];
    "x-scheme-handler/lycheeslicer" = [ "Lychee Slicer.desktop" ];
  };

  # High-speed Nix binary caches
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    max-jobs = "auto";
    cores = 0; # Use all CPU threads
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

  # Real-time PAM limits for ultra-low latency audio processing (PipeWire)
  security.pam.loginLimits = [
    { domain = "@audio"; item = "rtprio"; type = "-"; value = "99"; }
    { domain = "@audio"; item = "memlock"; type = "-"; value = "unlimited"; }
    { domain = "@audio"; item = "nice"; type = "-"; value = "-19"; }
  ];

  # NH CLI Helper (Visual diff previews, automatic generation retention & rebuild management)
  programs.nh = {
    enable = true;
    clean.enable = true;
    clean.extraArgs = "--keep 5";
    flake = "/etc/nixos";
  };

  # Automatic Garbage Collection fallback
  nix.gc = {
    automatic = false; # Handled dynamically by nh clean
  };

  # Enable nix-ld to run pre-compiled non-Nix binaries seamlessly
  programs.nix-ld.enable = true;

  # Allow Home Manager GTK/dconf settings to apply system-wide
  programs.dconf.enable = true;

  # Enable Docker container virtualization service with on-demand socket activation
  virtualisation.docker = {
    enable = true;
    enableOnBoot = false;
  };

  # Enable Podman for rootless container execution
  virtualisation.podman = {
    enable = true;
  };

  # Enable the system-wide SSH agent for credential caching
  programs.ssh.startAgent = true;

  # Enable the OpenSSH secure shell daemon (SSH server)
  services.openssh = {
    enable = true;
    startWhenNeeded = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "no";
    };
  };

  # Enable GNOME Online Accounts & Evolution Data Server for Google Calendar sync
  services.gnome.evolution-data-server.enable = true;
  services.gnome.gnome-online-accounts.enable = true;
  services.gnome.gnome-keyring.enable = true;
  services.gnome.gcr-ssh-agent.enable = false;

  # Basic system packages (core tools)
  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    vim
    pciutils
    usbutils
  ];

  # CPU Frequency Governor (Dynamic amd_pstate balance_performance mode; GameMode locks performance when gaming)
  powerManagement.cpuFreqGovernor = "powersave";

  # NixOS State Version
  system.stateVersion = "26.05";
}
