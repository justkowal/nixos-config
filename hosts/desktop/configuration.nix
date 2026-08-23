{
  config,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./overlays.nix
    ../../modules/boot.nix
    ../../modules/locale.nix
    ../../modules/user.nix
    ../../modules/nix-settings.nix
    ../../modules/services.nix
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
    ../../modules/audio-production.nix
    ../../modules/security.nix
    ../../modules/auto-update.nix
  ];



  home-manager.backupFileExtension = "backup";

  networking.hostName = "nixos-desktop";
  networking.networkmanager.enable = true;

  # Weekly filesystem integrity check
  systemd.services.bcachefs-scrub = {
    description = "Weekly Bcachefs Scrub";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bcachefs-tools}/bin/bcachefs fsck /dev/disk/by-uuid/91169176-2eea-4719-8327-2e0bbc3cc0c1";
    };
  };
  systemd.timers.bcachefs-scrub = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "weekly"; Persistent = true; };
  };


  # Real-time PAM limits for low-latency audio (PipeWire)
  security.pam.loginLimits = [
    { domain = "@audio"; item = "rtprio"; type = "-"; value = "99"; }
    { domain = "@audio"; item = "memlock"; type = "-"; value = "unlimited"; }
    { domain = "@audio"; item = "nice"; type = "-"; value = "-19"; }
  ];

  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    vim
    pciutils
    usbutils
  ];

  powerManagement.cpuFreqGovernor = "performance";

  system.stateVersion = "26.05";
}
