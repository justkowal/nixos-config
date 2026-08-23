# Networking, Security & Network Namespace VPN Manual

This document provides a 100% exhaustive reference manual for network interfaces, DNS, Tailscale, Syncthing, system firewall rules, isolated network namespaces (`vpnns`), OpenVPN, and headless qBittorrent defined in `modules/networking.nix` and `modules/vpn.nix`.

---

## 1. System Networking Infrastructure (`modules/networking.nix`)

- **Host Identifier**: `networking.hostName = "nixos-desktop"`.
- **Network Manager**: `networking.networkmanager.enable = true` (manages Ethernet & Wi-Fi interfaces).
- **DNS Resolution**:
  - Cloudflare Secure DNS Primary: `1.1.1.1`
  - Cloudflare Secure DNS Secondary: `1.0.0.1`
  - Specified via `networking.nameservers = [ "1.1.1.1" "1.0.0.1" ]`.
- **System Ingress Firewall**:
  - `networking.firewall.enable = true`
  - `trustedInterfaces = [ "tailscale0" ]` (Tailscale mesh network interface bypasses local firewall filters).

---

## 2. Mesh VPN & File Synchronization (`modules/networking.nix`)

### Tailscale Mesh Network (`services.tailscale`)
- Service enabled system-wide.
- Interface `tailscale0` added to trusted firewall interfaces for multi-device connectivity.

### Syncthing Decentralized File Sync (`services.syncthing`)
- User: `justkowal`
- Data Directory: `/home/justkowal/Sync`
- Configuration Directory: `/home/justkowal/.config/syncthing`

---

## 3. Isolated Network Namespace VPN Architecture (`modules/vpn.nix`)

To guarantee absolute privacy, torrenting and VPN traffic are isolated inside a dedicated Linux Network Namespace named **`vpnns`**. This completely prevents IP leaks, DNS leaks, or unencrypted traffic escaping to the host network.

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ Host Environment (10.200.1.1 on veth-host)                                      │
│  - System Firewall & Main Default Gateway                                      │
│  - Web Browser / Local GUI Apps                                                │
│                                                                                │
│   ▲                                                  ▲                         │
│   │ (veth-host <--> veth-ns)                         │ (Port 8080 WebUI)       │
│   ▼                                                  ▼                         │
│ ┌────────────────────────────────────────────────────────────────────────────┐ │
│ │ Network Namespace: vpnns (10.200.1.2 on veth-ns)                           │ │
│ │                                                                            │ │
│ │  1. OpenVPN Client Service (vpnns-openvpn.service)                         │ │
│ │     - Config: ~/.config/openvpn-config.ovpn                                │ │
│ │     - Establishes encrypted tun0 tunnel                                   │ │
│ │                                                                            │ │
│ │  2. Headless qBittorrent Service (services.qbittorrent)                    │ │
│ │     - Bound exclusively to interface: tun0                                 │ │
│ │     - WebUI Port: 8080 (Whitelisted for 10.200.1.0/24 subnet)             │ │
│ │                                                                            │ │
│ │  3. Strict iptables Firewall Rules (Kill-Switch)                           │ │
│ │     - INPUT / OUTPUT / FORWARD default policy: DROP                        │ │
│ │     - Traffic ONLY allowed on loopback (lo), tun+, or veth-ns subnet       │ │
│ └────────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────┘
```

### Namespace Setup (`systemd.services.vpnns`)
- **Type**: `oneshot` (`RemainAfterExit = true`).
- **Creation Commands**:
  ```bash
  ip netns add vpnns
  ip netns exec vpnns ip link set lo up
  ip link add veth-host type veth peer name veth-ns
  ip link set veth-ns netns vpnns
  ip addr add 10.200.1.1/24 dev veth-host
  ip link set veth-host up
  ip netns exec vpnns ip addr add 10.200.1.2/24 dev veth-ns
  ip netns exec vpnns ip link set veth-ns up
  ip netns exec vpnns ip route add default via 10.200.1.1
  ```

### Namespace Firewall & Kill-Switch Rules (iptables)
Executing inside `vpnns`:
1. Default Policy: `INPUT DROP`, `OUTPUT DROP`, `FORWARD DROP`.
2. Allow loopback: `lo` in/out ACCEPT.
3. Allow established state: `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT`.
4. Allow VPN tunnel traffic: `-i tun+ -j ACCEPT` and `-o tun+ -j ACCEPT`.
5. Allow root process to initiate tunnel: `-o veth-ns -m owner --uid-owner 0 -j ACCEPT`.
6. Allow local subnet for host WebUI access: `-s 10.200.1.0/24` and `-d 10.200.1.0/24` on `veth-ns` ACCEPT.

### OpenVPN Daemon inside Namespace (`systemd.services.vpnns-openvpn`)
- **Dependencies**: `after = [ "vpnns.service" ]`, `requires = [ "vpnns.service" ]`.
- **Command**: `ip netns exec vpnns openvpn --config /home/justkowal/.config/openvpn-config.ovpn`.
- **Restart Policy**: `Restart = "always"`, `RestartSec = 5`.

### Headless qBittorrent Daemon (`services.qbittorrent`)
- **User/Group**: `justkowal` / `users`.
- **Profile Directory**: `/var/lib/qBittorrent`.
- **WebUI Port**: `8080`.
- **Bound Network Interface**: `tun0` (`Preferences.Connection.Interface = "tun0"`).
- **WebUI Subnet Whitelist**: `10.200.1.0/24` (`AuthSubnetWhitelistEnabled = true`).
- **Download Save Path**: `/home/justkowal/Downloads`.
- **Namespace Binding (`systemd.services.qbittorrent`)**:
  - `bindsTo = [ "vpnns-openvpn.service" ]`
  - `after = [ "vpnns-openvpn.service" ]`
  - `serviceConfig.NetworkNamespacePath = "/var/run/netns/vpnns"`
  - `serviceConfig.ProtectHome = pkgs.lib.mkForce "no"`

### Host NAT & DNS inside Namespace
- **Host NAT**: `networking.nat.enable = true`, `internalInterfaces = [ "veth-host" ]`.
- **Namespace DNS**: Defined at `/etc/netns/vpnns/resolv.conf`:
  ```ini
  nameserver 1.1.1.1
  nameserver 1.0.0.1
  ```

### Passwordless Sudo Rule (`security.sudo.extraRules`)
Allows user `justkowal` to launch diagnostic commands or GUI apps inside the namespace without typing password:
```nix
{
  users = [ "justkowal" ];
  commands = [
    {
      command = "${pkgs.iproute2}/bin/ip netns exec vpnns *";
      options = [ "NOPASSWD" ];
    }
  ];
}
```

### GUI App Wrapper (`qbittorrent-vpn`)
Available in PATH:
```bash
qbittorrent-vpn
# Executes: sudo ip netns exec vpnns sudo -u justkowal env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" qbittorrent "$@"
```
