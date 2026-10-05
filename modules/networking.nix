{ config, pkgs, ... }:

{
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedTCPPorts = [
      4242    # lan-mouse software KVM
      53317   # LocalSend file transfer
    ];
    allowedUDPPorts = [
      4242    # lan-mouse software KVM
      53317   # LocalSend peer discovery
    ];
  };

  networking.nameservers = [ "1.1.1.1" "1.0.0.1" ];

  services.tailscale.enable = true;

  services.syncthing = {
    enable = true;
    user = "justkowal";
    dataDir = "/home/justkowal/Sync";
    configDir = "/home/justkowal/.config/syncthing";
    openDefaultPorts = true;
    overrideDevices = false;
    overrideFolders = false;
  };

  environment.systemPackages = with pkgs; [
    wakeonlan
  ];

  programs.mosh.enable = true;
}
