{ config, pkgs, ... }:

{
  # 1. System packages needed for VPN and isolated torrenting
  environment.systemPackages = with pkgs; [
    openvpn
    qbittorrent # Still provide GUI in case the user wants it
    # Wrapper script that runs qbittorrent GUI inside vpnns network namespace
    (writeShellScriptBin "qbittorrent-vpn" ''
      exec sudo ${pkgs.iproute2}/bin/ip netns exec vpnns sudo -u justkowal env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" ${pkgs.qbittorrent}/bin/qbittorrent "$@"
    '')
  ];

  # 2. Network Namespace Setup Service
  systemd.services.vpnns = {
    description = "VPN Network Namespace Setup";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "vpnns-start" ''
        # Reset any existing namespace state
        ${pkgs.iproute2}/bin/ip netns del vpnns 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip link del veth-host 2>/dev/null || true

        # Create namespace
        ${pkgs.iproute2}/bin/ip netns add vpnns
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iproute2}/bin/ip link set lo up

        # Create veth pair for routing
        ${pkgs.iproute2}/bin/ip link add veth-host type veth peer name veth-ns
        ${pkgs.iproute2}/bin/ip link set veth-ns netns vpnns

        # Assign IPs and bring interfaces up
        ${pkgs.iproute2}/bin/ip addr add 10.200.1.1/24 dev veth-host
        ${pkgs.iproute2}/bin/ip link set veth-host up

        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iproute2}/bin/ip addr add 10.200.1.2/24 dev veth-ns
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iproute2}/bin/ip link set veth-ns up

        # Default route inside namespace to the host gateway
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iproute2}/bin/ip route add default via 10.200.1.1

        # Configure namespace firewall rules (VPN kill-switch & Leak protection)
        # 1. Reset rules
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -F
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -X

        # 2. Default drop policy
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -P INPUT DROP
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -P OUTPUT DROP
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -P FORWARD DROP

        # 3. Allow loopback
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A INPUT -i lo -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A OUTPUT -o lo -j ACCEPT

        # 4. Allow established connections
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        # 5. Allow all traffic on the VPN interface (tun+)
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A INPUT -i tun+ -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A OUTPUT -o tun+ -j ACCEPT

        # 6. Allow root (uid 0) to send traffic over veth-ns to establish VPN tunnel
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A OUTPUT -o veth-ns -m owner --uid-owner 0 -j ACCEPT

        # 7. Allow local subnet traffic on veth-ns for Web UI access
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A INPUT -i veth-ns -s 10.200.1.0/24 -j ACCEPT
        ${pkgs.iproute2}/bin/ip netns exec vpnns ${pkgs.iptables}/bin/iptables -A OUTPUT -o veth-ns -d 10.200.1.0/24 -j ACCEPT
      '';
      ExecStop = pkgs.writeShellScript "vpnns-stop" ''
        ${pkgs.iproute2}/bin/ip link del veth-host 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip netns del vpnns 2>/dev/null || true
      '';
    };
  };

  # 3. OpenVPN Systemd Service inside vpnns
  systemd.services.vpnns-openvpn = {
    description = "OpenVPN inside vpnns network namespace";
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

  # 4. Declarative Headless qBittorrent Service inside vpnns namespace
  services.qbittorrent = {
    enable = true;
    user = "justkowal";
    group = "users";
    profileDir = "/var/lib/qBittorrent";
    webuiPort = 8080;
    serverConfig = {
      LegalNotice = {
        Accepted = true;
      };
      Preferences = {
        Connection = {
          Interface = "tun0";
          InterfaceName = "tun0";
        };
        General = {
          Locale = "en";
        };
        WebUI = {
          AuthSubnetWhitelistEnabled = true;
          AuthSubnetWhitelist = "10.200.1.0/24";
        };
        Downloads = {
          SavePath = "/home/justkowal/Downloads";
        };
      };
    };
  };

  # Override qbittorrent service to run inside the network namespace and allow writing to /home
  systemd.services.qbittorrent = {
    bindsTo = [ "vpnns-openvpn.service" ];
    after = [ "vpnns-openvpn.service" ];
    serviceConfig = {
      NetworkNamespacePath = "/var/run/netns/vpnns";
      ProtectHome = pkgs.lib.mkForce "no";
    };
  };

  # 5. NAT routing on the host to allow the namespace to connect outwards
  networking.nat = {
    enable = true;
    internalInterfaces = [ "veth-host" ];
  };

  # 6. DNS Resolution configuration inside the namespace
  environment.etc."netns/vpnns/resolv.conf" = {
    text = ''
      nameserver 1.1.1.1
      nameserver 1.0.0.1
    '';
  };

  # 7. Sudo Rules to allow justkowal to execute commands in the namespace without password (for GUI or diagnostics)
  security.sudo.extraRules = [
    {
      users = [ "justkowal" ];
      commands = [
        {
          command = "${pkgs.iproute2}/bin/ip netns exec vpnns *";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
