# NixOS System Reference

This directory contains the detailed documentation for the `/etc/nixos` Flake configuration.

> [!NOTE]
> This documentation supplements the root `README.md` by providing deep dives into specific architectural components, network configurations, and UI customizations.

## Documentation Index

| Topic | Description |
| :--- | :--- |
| [**System Architecture**](SYSTEM_ARCHITECTURE.md) | Flake targets, XanMod custom kernel, ROCm setup, storage, and tuning. |
| [**Deployment Guide**](DEPLOYMENT.md) | Step-by-step homelab deployment (RPi4 orchestrator, Desktop worker, Laptop client). |
| [**Usage & Operations Manual**](USAGE.md) | Accessing services from laptop, Kanidm SSO, Forgejo, Woodpecker, Flamenco, and SSH sandbox. |
| [**Desktop Environment**](DESKTOP_ENVIRONMENT.md) | Hyprland, Waybar, Rofi, Kitty, and full keybinding reference. |
| [**Ambient AI Suite**](AMBIENT_AI.md) | Local Gemma models, vector indexing, AI daemons, and shell integrations. |
| [**Networking & VPN**](NETWORKING_AND_VPN.md) | Tailscale, Syncthing, Firewall rules, and isolated network namespaces. |

## Quick Command Reference

> [!TIP]
> The `nh` tool is the recommended way to build and switch configurations.

```bash
# Rebuild System Configuration
nh os switch /etc/nixos

# Test Build System without activating
nh os build /etc/nixos

# Clean Old Generations (keep last 5)
nh clean all --keep 5

# Check VPN namespace status
sudo ip netns exec vpnns ip addr
```
