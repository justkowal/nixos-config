{ config, pkgs, lib, ... }:

{
  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "15s";
    DefaultTimeoutStopSec = "10s";
    DefaultDeviceTimeoutSec= "15s";
  };

  systemd.coredump.enable = true;
  systemd.oomd.enable = false;

  services.journald.extraConfig = ''
    Storage=volatile
    SystemMaxUse=50M
    RuntimeMaxUse=50M
    SyncIntervalSec=5m
    MaxRetentionSec=14day
  '';

  # Disabled by default for fast-boot headless/laptop hosts.
  # Desktop overrides these in its configuration.nix so WoL DHCP leases
  # are guaranteed before CI agents start.
  systemd.targets.network-online.wantedBy = lib.mkDefault [];
  systemd.services.NetworkManager-wait-online.enable = lib.mkDefault false;
}
