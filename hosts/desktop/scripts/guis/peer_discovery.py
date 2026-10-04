#!/usr/bin/env python3
"""
Dynamic Peer & Fleet Discovery Engine
Resolves fleet nodes (Desktop, Laptop, RPi4) dynamically:
- Queries Tailscale daemon (`tailscale status --json`) for real-time mesh connectivity and IPs
- Resolves local network names via DNS/mDNS (.lab, .local, system resolver)
- Identifies local host role (Desktop workstation vs ThinkPad laptop)
- Selects optimal active route (low-latency LAN when available, encrypted Tailscale mesh fallback)
- ZERO hardcoded static IPs
"""

import json
import socket
import subprocess
from typing import Dict, Any, Optional

FLEET_SPECS = {
    "desktop": {
        "key": "desktop",
        "name": "nixos-desktop",
        "glyph": "󰞷",
        "title": "nixos-desktop (Workstation)",
        "role": "Workstation (Ryzen 7 5700X · RX 6700 XT)",
        "dns_candidates": ["nixos-desktop.lab", "nixos-desktop.local", "nixos-desktop"],
        "tailscale_match": ["desktop", "nixos-desktop"]
    },
    "laptop": {
        "key": "laptop",
        "name": "thinkpad-t14s-gen1-amd",
        "glyph": "󰌢",
        "title": "thinkpad-laptop (ThinkPad T14s)",
        "role": "Mobile Client (Ryzen 7 PRO 4750U · Tailscale Mesh)",
        "dns_candidates": ["thinkpad-t14s-gen1-amd.lab", "thinkpad-t14s-gen1-amd.local", "thinkpad-t14s-gen1-amd"],
        "tailscale_match": ["thinkpad", "t14s", "thinkpad-t14s-gen1-amd"]
    },
    "rpi4": {
        "key": "rpi4",
        "name": "nixos-rpi4",
        "glyph": "󰒋",
        "title": "nixos-rpi4 (Homelab Core Server)",
        "role": "Homelab Infrastructure (DNS, Caddy, Vault, Git, CI)",
        "dns_candidates": ["nixos-rpi4.lab", "nixos-rpi4.local", "nixos-rpi4"],
        "tailscale_match": ["rpi4", "raspberry", "nixos-rpi4"]
    }
}

def get_local_host_key() -> str:
    """Returns 'desktop', 'laptop', or 'rpi4' based on system hostname."""
    hname = socket.gethostname().lower()
    if "laptop" in hname or "thinkpad" in hname or "t14s" in hname:
        return "laptop"
    if "desktop" in hname:
        return "desktop"
    if "rpi" in hname or "raspberry" in hname:
        return "rpi4"
    return "unknown"

def probe_ping(ip: str, timeout_sec: int = 1) -> Optional[float]:
    """Pings an IP address and returns round-trip latency in ms, or None if unreachable."""
    if not ip or ip == "127.0.0.1":
        return 0.1
    try:
        proc = subprocess.run(
            ["ping", "-c", "1", "-W", str(timeout_sec), ip],
            capture_output=True,
            text=True,
            timeout=timeout_sec + 1
        )
        if proc.returncode == 0:
            for line in proc.stdout.splitlines():
                if "rtt" in line or "round-trip" in line:
                    rtt = line.split("/")[4]
                    return float(rtt)
            return 1.0
    except Exception:
        pass
    return None

def query_tailscale_peers() -> Dict[str, Dict[str, Any]]:
    """Queries `tailscale status --json` and maps peers to fleet keys."""
    peers = {}
    try:
        proc = subprocess.run(
            ["tailscale", "status", "--json"],
            capture_output=True,
            text=True,
            timeout=2
        )
        if proc.returncode == 0:
            ts_data = json.loads(proc.stdout)
            
            # Map Self node
            self_node = ts_data.get("Self", {})
            self_h = self_node.get("HostName", "").lower()
            self_ips = self_node.get("TailscaleIPs", [])
            self_ip = self_ips[0] if self_ips else None

            # Map Peer nodes
            peer_dict = ts_data.get("Peer", {})
            for _, peer in peer_dict.items():
                hname = peer.get("HostName", "").lower()
                online = peer.get("Online", False)
                ts_ips = peer.get("TailscaleIPs", [])
                tip = ts_ips[0] if ts_ips else None
                dns = peer.get("DNSName", "").rstrip(".")

                for fkey, spec in FLEET_SPECS.items():
                    if any(m in hname for m in spec["tailscale_match"]):
                        peers[fkey] = {
                            "online": online,
                            "ts_ip": tip,
                            "dns": dns,
                            "hostname": peer.get("HostName")
                        }
                        break
    except Exception:
        pass
    return peers

def resolve_fleet_node(node_key: str, ts_peers: Optional[Dict[str, Dict[str, Any]]] = None) -> Dict[str, Any]:
    """
    Dynamically resolves a single fleet node without static IPs.
    Returns:
      {
        "key": node_key,
        "name": hostname,
        "title": display_title,
        "role": description,
        "local": bool,
        "online": bool,
        "active_ip": str,
        "route_type": "Local Loopback" | "LAN" | "Tailscale" | "Unresolved",
        "latency_ms": float | None,
        "lan_ip": str | None,
        "ts_ip": str | None
      }
    """
    spec = FLEET_SPECS.get(node_key)
    if not spec:
        raise ValueError(f"Unknown fleet node: {node_key}")

    local_key = get_local_host_key()
    if node_key == local_key:
        return {
            "key": node_key,
            "name": spec["name"],
            "title": spec["title"],
            "role": spec["role"],
            "local": True,
            "online": True,
            "active_ip": "127.0.0.1",
            "route_type": "Local Loopback",
            "latency_ms": 0.0,
            "lan_ip": "127.0.0.1",
            "ts_ip": None
        }

    if ts_peers is None:
        ts_peers = query_tailscale_peers()

    ts_info = ts_peers.get(node_key, {})
    ts_ip = ts_info.get("ts_ip")
    ts_online = ts_info.get("online", False)

    # 1. Resolve local LAN IP dynamically via DNS candidates (.lab, .local, hostname)
    lan_ip = None
    for cand in spec["dns_candidates"]:
        try:
            resolved = socket.gethostbyname(cand)
            if resolved and not resolved.startswith("127."):
                lan_ip = resolved
                break
        except Exception:
            continue

    # 2. Check LAN connectivity first (lower latency on home network)
    active_ip = None
    route_type = "Unresolved"
    latency = None
    online = False

    if lan_ip:
        rtt = probe_ping(lan_ip, timeout_sec=1)
        if rtt is not None:
            active_ip = lan_ip
            route_type = "LAN"
            latency = rtt
            online = True

    # 3. Fallback to Tailscale mesh IP (works anywhere in the world)
    if not online and ts_ip:
        rtt = probe_ping(ts_ip, timeout_sec=1)
        if rtt is not None:
            active_ip = ts_ip
            route_type = "Tailscale"
            latency = rtt
            online = True
        elif ts_online:
            active_ip = ts_ip
            route_type = "Tailscale"
            online = True

    if not active_ip:
        active_ip = ts_ip or lan_ip or spec["name"]

    return {
        "key": node_key,
        "name": spec["name"],
        "title": spec["title"],
        "role": spec["role"],
        "local": False,
        "online": online,
        "active_ip": active_ip,
        "route_type": route_type,
        "latency_ms": latency,
        "lan_ip": lan_ip,
        "ts_ip": ts_ip
    }

def resolve_all_nodes() -> Dict[str, Dict[str, Any]]:
    """Resolves all nodes in the fleet simultaneously."""
    ts_peers = query_tailscale_peers()
    return {k: resolve_fleet_node(k, ts_peers) for k in FLEET_SPECS}

if __name__ == "__main__":
    import pprint
    print(f"Local Host Role: {get_local_host_key()}")
    print("Resolving entire fleet dynamically...")
    fleet = resolve_all_nodes()
    pprint.pprint(fleet)
