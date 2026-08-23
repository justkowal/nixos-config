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

  systemd.targets.network-online.wantedBy = lib.mkForce [];
  systemd.services.NetworkManager-wait-online.enable = false;
}
