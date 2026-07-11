{ config, pkgs, lib, ... }:

{
  # 1. Optimize systemd timeouts (prevents hanging on shutdowns/boots)
  systemd.extraConfig = ''
    DefaultTimeoutStartSec=15s
    DefaultTimeoutStopSec=10s
    DefaultDeviceTimeoutSec=15s
  '';

  # 2. Disable systemd coredump storage (saves CPU and disk write overhead on crashes)
  systemd.coredump.enable = false;

  # 3. Disable systemd Out Of Memory daemon (reduces background CPU/ram usage)
  systemd.oomd.enable = false;

  # 4. Minimize logging footprint (store journal in volatile memory / limit size)
  services.journald.extraConfig = ''
    Storage=volatile
    SystemMaxUse=50M
    RuntimeMaxUse=50M
  '';

  # 5. Disable waiting for network online target to avoid blocking boot
  systemd.targets.network-online.wantedBy = lib.mkForce [];
  systemd.services.NetworkManager-wait-online.enable = false;
}
