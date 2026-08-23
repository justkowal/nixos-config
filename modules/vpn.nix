{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    openvpn
    qbittorrent
    (writeShellScriptBin "qbittorrent-vpn" ''
      exec sudo ${pkgs.iproute2}/bin/ip netns exec vpnns sudo -u justkowal env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" ${pkgs.qbittorrent}/bin/qbittorrent "$@"
    '')
  ];

  # Network namespace for VPN isolation
  systemd.services.vpnns = {
    description = "VPN Network Namespace";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "vpnns-start" ''
        ${pkgs.iproute2}/bin/ip netns del vpnns 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip link del veth-host 2>/dev/null || true

        ${pkgs.iproute2}/bin/ip netns add vpnns
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iproute2}/bin/ip link set lo up

        ${pkgs.iproute2}/bin/ip link add veth-host type veth peer name veth-ns
        ${pkgs.iproute2}/bin/ip link set veth-ns netns vpnns

        ${pkgs.iproute2}/bin/ip addr add 10.200.1.1/24 dev veth-host
        ${pkgs.iproute2}/bin/ip link set veth-host up

        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iproute2}/bin/ip addr add 10.200.1.2/24 dev veth-ns
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iproute2}/bin/ip link set veth-ns up
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iproute2}/bin/ip route add default via 10.200.1.1

        # Kill-switch firewall inside namespace
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -F
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -X
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -P INPUT DROP
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -P OUTPUT DROP
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -P FORWARD DROP
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A INPUT -i lo -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A OUTPUT -o lo -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A INPUT -i tun+ -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A OUTPUT -o tun+ -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A OUTPUT -o veth-ns -m owner --uid-owner 0 -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A INPUT -i veth-ns -s 10.200.1.0/24 -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A OUTPUT -o veth-ns -d 10.200.1.0/24 -j ACCEPT
      '';
      ExecStop = pkgs.writeShellScript "vpnns-stop" ''
        ${pkgs.iproute2}/bin/ip link del veth-host 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip netns del vpnns 2>/dev/null || true
      '';
    };
  };

  systemd.services.vpnns-openvpn = {
    description = "OpenVPN inside vpnns";
    after = [ "vpnns.service" ];
    requires = [ "vpnns.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.openvpn}/bin/openvpn --config /home/justkowal/.config/openvpn-config.ovpn";
      Restart = "always";
      RestartSec = 5;
    };
  };

  services.qbittorrent = {
    enable = true;
    user = "justkowal";
    group = "users";
    profileDir = "/var/lib/qBittorrent";
    webuiPort = 8080;
    serverConfig = {
      LegalNotice.Accepted = true;
      Preferences = {
        Connection = { Interface = "tun0"; InterfaceName = "tun0"; };
        General.Locale = "en";
        WebUI = { AuthSubnetWhitelistEnabled = true; AuthSubnetWhitelist = "10.200.1.0/24"; };
        Downloads.SavePath = "/home/justkowal/Downloads";
      };
    };
  };

  systemd.services.qbittorrent = {
    bindsTo = [ "vpnns-openvpn.service" ];
    after = [ "vpnns-openvpn.service" ];
    serviceConfig = {
      NetworkNamespacePath = "/var/run/netns/vpnns";
      ProtectHome = pkgs.lib.mkForce "no";
    };
  };

  networking.nat = { enable = true; internalInterfaces = [ "veth-host" ]; };

  environment.etc."netns/vpnns/resolv.conf".text = ''
    nameserver 1.1.1.1
    nameserver 1.0.0.1
  '';

  security.sudo.extraRules = [{
    users = [ "justkowal" ];
    commands = [{ command = "${pkgs.iproute2}/bin/ip netns exec vpnns *"; options = [ "NOPASSWD" ]; }];
  }];
}
