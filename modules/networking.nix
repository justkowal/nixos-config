{ config, pkgs, ... }:

{
  # 1. System Firewall (enabled by default)
  networking.firewall = {
    enable = true;
    # Allow Tailscale interface to bypass firewall restrictions locally
    trustedInterfaces = [ "tailscale0" ];
  };

  # 2. Cloudflare Secure DNS Nameservers
  networking.nameservers = [ "1.1.1.1" "1.0.0.1" ];

  # 3. Tailscale Mesh VPN
  services.tailscale.enable = true;

  # 4. Syncthing (Continuous decentralized file synchronization)
  services.syncthing = {
    enable = true;
    user = "justkowal";
    dataDir = "/home/justkowal/Sync"; # Default sync directory
    configDir = "/home/justkowal/.config/syncthing"; # Config storage
  };
}
