# NixOS System-Wide Configuration Wiki & Reference Manual

Welcome to the 100% exhaustive system documentation and reference manual for this NixOS Flake codebase (`/etc/nixos`).

---

## 📚 Complete Wiki Navigation

- 🏗️ [**System Architecture & Hardware Kernel Guide**](SYSTEM_ARCHITECTURE.md)  
  *Flake targets, custom XanMod LTO kernel compilation, AMD ROCm HIP runtime, ZRAM swap, sysctl tuning, Bcachefs storage, PAM limits, and NH helper.*

- 🎨 [**Desktop Environment & User Interface**](DESKTOP_ENVIRONMENT.md)  
  *Hyprland Wayland compositor, Greetd display manager, Waybar status bar, SwayNC, Rofi menus, Kitty terminal, XDG MIME defaults, and complete keybindings table.*

- 🤖 [**Ambient AI Integration Suite**](AMBIENT_AI.md)  
  *Invisible background AI daemons, local Gemma 4 Ollama ROCm backend, model tiering (E2B, E4B, 12B), 7 ambient services, Nushell AI shell commands, PDF RAG, and vector search.*

- 🌐 [**Networking, Security & Isolated Network Namespace VPN**](NETWORKING_AND_VPN.md)  
  *Tailscale mesh network, Syncthing file sync, Cloudflare DNS, system firewall rules, isolated `vpnns` network namespace with iptables kill-switch, and headless qBittorrent daemon.*

---

## 📂 Repository File Index & Map

| File Path | Description / Role |
| :--- | :--- |
| [`flake.nix`](file:///etc/nixos/flake.nix) | Main Flake entrypoint defining inputs (`nixpkgs`, `home-manager`, `millennium`, `antigravity-nix`) and host outputs (`desktop`, `laptop`, `vm`, `iso`). |
| [`hosts/desktop/configuration.nix`](file:///etc/nixos/hosts/desktop/configuration.nix) | Core system configuration for the primary desktop workstation (Ryzen CPU, RX 6700 XT GPU, Bcachefs, user account). |
| [`hosts/desktop/hardware-configuration.nix`](file:///etc/nixos/hosts/desktop/hardware-configuration.nix) | Hardware probe config, kernel modules (`nvme`, `xhci_pci`, `ahci`, `usbhid`, `kvm-amd`), filesystem mount points (`/` Bcachefs, `/boot/efi` VFAT). |
| [`hosts/desktop/home.nix`](file:///etc/nixos/hosts/desktop/home.nix) | Primary Home Manager module declaring userland applications, Waybar config & CSS, Hyprland rules, Rofi power menu, and Continue extension config. |
| [`hosts/desktop/home-ai.nix`](file:///etc/nixos/hosts/desktop/home-ai.nix) | Complete declarative Ambient AI Suite module (daemons, timers, Rofi AI popups, Nushell helpers, vector search, Spotlight integration). |
| [`hosts/desktop/home-theming.nix`](file:///etc/nixos/hosts/desktop/home-theming.nix) | Theme design system, GTK colors, cursor themes, font tokens, wallpaper settings. |
| [`hosts/laptop/configuration.nix`](file:///etc/nixos/hosts/laptop/configuration.nix) | Mobile laptop target configuration with TLP power management. |
| [`hosts/vm/configuration.nix`](file:///etc/nixos/hosts/vm/configuration.nix) | Virtual Machine guest profile with SPICE and QEMU integration. |
| [`hosts/iso/configuration.nix`](file:///etc/nixos/hosts/iso/configuration.nix) | Bootable live installer ISO target with interactive `install-tui.sh` wizard. |
| [`modules/ai.nix`](file:///etc/nixos/modules/ai.nix) | System-wide Ollama daemon with ROCm GPU acceleration, local SearXNG engine (`:8888`), and Open-WebUI (`:11111`). |
| [`modules/apps.nix`](file:///etc/nixos/modules/apps.nix) | System applications (Steam Millennium, Firefox, Discord, Blender ROCm HIP wrap, OBS Studio with wlrobs, FreeCAD, KiCad, LaTeX). |
| [`modules/desktop.nix`](file:///etc/nixos/modules/desktop.nix) | Hyprland compositor enable, Greetd + Tuigreet login manager, XDG portals, PipeWire low-latency audio stack, polkit security. |
| [`modules/hardware.nix`](file:///etc/nixos/modules/hardware.nix) | AMD GPU overclocking mask (`amdgpu.ppfeaturemask`), Bluetooth & Blueman, game controllers (`xone`, `joycond`), OpenRGB, Ratbagd, CUPS printing. |
| [`modules/kernel.nix`](file:///etc/nixos/modules/kernel.nix) | Custom XanMod LTO kernel compilation block (`stdenv = llvmPackages_latest.stdenv`, `-march=znver3`), kernel pruning, sysctl kernel parameters. |
| [`modules/networking.nix`](file:///etc/nixos/modules/networking.nix) | NetworkManager, Cloudflare DNS (`1.1.1.1`), Tailscale mesh VPN daemon, and Syncthing decentralized file synchronization. |
| [`modules/performance.nix`](file:///etc/nixos/modules/performance.nix) | zramSwap (`zstd`), dbus-broker, TCP BBR congestion control, Ananicy-cpp CachyOS rules, Feral GameMode, LACT GPU daemon, GameScope, udev I/O schedulers. |
| [`modules/shell.nix`](file:///etc/nixos/modules/shell.nix) | Nushell default interactive shell setup, Starship prompt, direnv & nix-direnv, uutils rust-coreutils. |
| [`modules/systemd-minimal.nix`](file:///etc/nixos/modules/systemd-minimal.nix) | Systemd boot/shutdown timeout tuning, volatile in-memory journald logging, disabling coredump and systemd-oomd. |
| [`modules/vpn.nix`](file:///etc/nixos/modules/vpn.nix) | Isolated network namespace (`vpnns`), OpenVPN client inside namespace, iptables kill-switch & leak protection, headless qBittorrent bound to `vpnns`. |

---

## ⚡ Essential Command Reference

### System Operations
- **Rebuild System Configuration**: `sudo nixos-rebuild switch --flake /etc/nixos#desktop`
- **Test Build System**: `sudo nixos-rebuild build --flake /etc/nixos#desktop`
- **NH Helper Rebuild**: `nh os switch /etc/nixos`
- **Clean Old Generations**: `nh clean all --keep 5`

### Network & VPN Operations
- **Launch GUI app in VPN namespace**: `qbittorrent-vpn`
- **Check VPN namespace status**: `sudo ip netns exec vpnns ip addr`
- **Check VPN namespace routing**: `sudo ip netns exec vpnns curl ifconfig.me`

### AI Operations
- **Instant Shell Assistant**: `ai "how do I check open ports in linux?"`
- **Task & Code Assistant**: `ai-task "write a python script to parse json"`
- **Deep Analysis Assistant**: `ai-papa "explain bcachefs vs zfs architecture"`
- **Diagnose System Logs**: `ai-debug`
- **Vector Search Files**: `vector-search "invoice 2026"`
- **Vector Search Clipboard**: `clip-search "git commit"`
- **Interactive PDF Q&A**: `pdf-qa /path/to/document.pdf "what is the summary?"`
- **Manual File Organizer**: `ai-organize ~/Downloads` (or `ai-organize --dry-run` / `ai-organize --undo`)
