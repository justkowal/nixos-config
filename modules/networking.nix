{ config, pkgs, ... }:

{
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
  };

  networking.nameservers = [ "1.1.1.1" "1.0.0.1" ];

  services.tailscale.enable = true;

  services.syncthing = {
    enable = true;
    user = "justkowal";
    dataDir = "/home/justkowal/Sync";
    configDir = "/home/justkowal/.config/syncthing";
  };
}
