# System Architecture & Hardware Kernel Documentation

This document provides a 100% exhaustive, low-level technical specification of the system architecture, hardware configuration, kernel compilation, memory management, and performance tuning defined across the NixOS codebase.

---

## 1. Multi-Host Flake Architecture (`flake.nix`)

The system relies on Nix Flakes with inputs:
- `nixpkgs`: Tracking channel `github:nixos/nixpkgs/nixos-26.05`.
- `millennium`: Steam client customization framework (`github:SteamClientHomebrew/Millennium?dir=packages/nix`).
- `antigravity-nix`: Google Antigravity IDE and CLI tools (`github:jacopone/antigravity-nix`).
- `home-manager`: Userland environment manager (`github:nix-community/home-manager`).

### Host Targets Matrix
1. **`desktop` / `nixos-desktop`** (`hosts/desktop/configuration.nix`):
   - Architecture: `x86_64-linux`.
   - Core Modules Included: `hardware-configuration.nix`, `kernel.nix`, `desktop.nix`, `shell.nix`, `apps.nix`, `systemd-minimal.nix`, `performance.nix`, `hardware.nix`, `networking.nix`, `vpn.nix`, `ai.nix`.
   - User Account: `justkowal` (Groups: `networkmanager`, `wheel`, `video`, `render`, `docker`).
   - Timezone & Locales: `Europe/Warsaw`, `en_US.UTF-8` (primary), `pl_PL.UTF-8` (supported), Console Keymap `pl2`.

2. **`laptop`** (`hosts/laptop/configuration.nix`):
   - Configured for portable devices with battery management (TLP/auto-cpufreq).

3. **`vm`** (`hosts/vm/configuration.nix`):
   - Optimized QEMU/KVM guest target with SPICE agent integration.

4. **`iso`** (`hosts/iso/configuration.nix`):
   - Live bootable ISO target equipped with custom TUI installation script (`install-tui.sh`).

---

## 2. Bootloader & Storage Architecture

### Boot Configuration (`hosts/desktop/configuration.nix`)
- **Bootloader**: `systemd-boot` enabled (`boot.loader.systemd-boot.enable = true`).
- **Timeout**: `boot.loader.timeout = 0` (instant boot without countdown menu).
- **EFI Setup**: EFI variables enabled (`canTouchEfiVariables = true`), mount point `/boot/efi`.
- **ESP Random Seed**: Disabled (`systemd.services.systemd-boot-random-seed.enable = false`) to eliminate slow VFAT write sync delays during boot.
- **Stage 1 Initrd**:
  - `boot.initrd.systemd.enable = true`
  - Compression: `zstd`
  - `includeDefaultModules = false` (pruned initrd module set)
  - `boot.consoleLogLevel = 0` and `verbose = false` for silent fast boot.

### Filesystem Layout & Scrubbing (`hosts/desktop/hardware-configuration.nix`)
- **Root Filesystem (`/`)**:
  - Device UUID: `91169176-2eea-4719-8327-2e0bbc3cc0c1`
  - Filesystem Type: `bcachefs`
  - Mount Options: `compression=zstd`, `noatime`
  - Supported filesystems: `boot.supportedFilesystems = ["bcachefs"]`
- **EFI Boot Partition (`/boot/efi`)**:
  - Device Label: `boot`
  - Filesystem Type: `vfat`
  - Mount Options: `fmask=0077`, `dmask=0077`, `noatime`, `lazytime`, `async`
- **Bcachefs Health Maintenance**:
  - Service: `systemd.services.bcachefs-scrub` (`oneshot`)
  - Timer: `systemd.timers.bcachefs-scrub` (runs `bcachefs fsck` weekly, persistent).

---

## 3. XanMod LTO Custom Kernel Compilation (`modules/kernel.nix`)

The desktop profile compiles a custom trimmed Linux kernel derived from `linuxPackages_xanmod_latest`:

### Toolchain & Flag Overrides
- **Compiler**: `stdenv = pkgs.llvmPackages_latest.stdenv` (Clang/LLVM toolchain).
- **Target CPU Flags**: `KCFLAGS+=-march=znver3`, `KCFLAGS+=-mtune=znver3` (Optimized specifically for AMD Zen 3 Ryzen architecture).
- **Link-Time Optimization**: `LTO = yes`, `LTO_CLANG = yes`, `LTO_CLANG_THIN = yes`.
- **NUMA**: `NUMA = no` (Disabled to eliminate NUMA balance overhead on single-CCD Zen 3 CPUs).

### Scheduler & Latency Configuration
- **Clock Frequency**: `HZ_1000 = yes` (1000 Hz timer frequency for low audio/input latency).
- **Preemption**: `PREEMPT = yes` (Full preemptible kernel mode; runtime `preempt=full`).
- **Autogroup**: `SCHED_AUTOGROUP = no`.
- **RCU Tuning**: `RCU_EXPERT = yes`, `RCU_BOOST = yes`.
- **Hugepages**: `TRANSPARENT_HUGEPAGE = yes`, `TRANSPARENT_HUGEPAGE_ALWAYS = yes` (runtime kernel param `transparent_hugepage=always`).
- **Mitigations**: `mitigations=off` (Disables speculative execution mitigations for maximum raw CPU execution performance).

### Kernel Pruning (Disabled Subsystems)
- **Wireless**: `WLAN = no`, `WIRELESS = no`, `CFG80211 = no`, `MAC80211 = no`.
- **Unused GPUs**: `DRM_I915 = no`, `DRM_NOUVEAU = no`, `DRM_RADEON = no`, `DRM_VIRTIO_GPU = no`, `DRM_VMWGFX = no`, `DRM_GMA500 = no`, `DRM_HYPERV = no` (Only `DRM_AMDGPU = yes` is retained).
- **Hypervisors**: `HYPERVISOR_GUEST = no`, `XEN = no`, `HYPERV = no`.
- **Ethernet Drivers**: Pruned all vendors except Realtek (`NET_VENDOR_REALTEK = yes`, `R8169 = yes`).
- **Buses & Media**: Pruned PCCARD, CARDBUS, INFINIBAND, HAMRADIO, CAN, ISDN, Analog/Digital TV/SDR tuners. Retained USB (xHCI/EHCI/OHCI/Storage/HID/ACM/Serial FTDI/CP210X/CH341/PL2303).

---

## 4. Hardware Subsystems & Drivers (`modules/hardware.nix` & `modules/desktop.nix`)

### AMD Radeon RX 6700 XT GPU (Navi 22) Setup
- **Kernel Parameter**: `amdgpu.ppfeaturemask=0xffffffff` (Unlocks full GPU overclocking, undervolting, power limit, and custom fan curve controls in LACT).
- **Graphics Stack (`hardware.graphics`)**:
  - 32-bit driver support enabled (`enable32Bit = true`).
  - ROCm packages: `rocmPackages.clr`, `rocmPackages.clr.icd`.
  - Environment override: `HSA_OVERRIDE_GFX_VERSION = "10.3.0"` (maps Navi 22 `gfx1031` to `gfx1030` ROCm target).
- **Blender HIP Fix**:
  - Systemd tmpfiles rule creating `/opt/rocm/hip -> ${pkgs.rocmPackages.clr}` symlink.
  - Blender package wrapped in `modules/apps.nix` with `LD_PRELOAD` pointing to `${rocmPackages.rocm-comgr}/lib/libamd_comgr.so.3` to prevent HIP compiler crashes.

### Peripherals & RGB Control
- **Bluetooth**: `hardware.bluetooth.enable = true`, managed via `services.blueman.enable = true` (Blueman GUI).
- **Game Controllers**:
  - `hardware.xone.enable = true` (Xbox One/Series wired and wireless dongle driver).
  - `services.joycond.enable = true` (Nintendo Switch Joy-Con / Pro Controller daemon).
  - `hardware.steam-hardware.enable = true` (Steam Controller / Deck udev rules).
- **RGB & Peripherals**:
  - `services.hardware.openrgb`: Package `pkgs.openrgb-with-all-plugins`, kernel modules `i2c-dev`, `i2c-piix4`.
  - `services.ratbagd.enable = true` (Libratbag gaming mouse daemon for Piper GUI).
- **Printing**: `services.printing`: CUPS printer daemon enabled with `startWhenNeeded = true`.

---

## 5. Performance Tuning & Sysctl (`modules/performance.nix`)

### zramSwap Configuration
- Algorithm: `zstd`
- Memory Percentage: `50%` of physical RAM
- Priority: `10`

### D-Bus Daemon Implementation
- `services.dbus.implementation = "broker"` (Replaces legacy D-Bus daemon with high-performance `dbus-broker`).

### TCP BBR & Network Buffer Tuning
- Kernel Module: `tcp_bbr`
- `net.core.default_qdisc = "fq"`
- `net.ipv4.tcp_congestion_control = "bbr"`
- `net.ipv4.tcp_slow_start_after_idle = 0`
- `net.ipv4.tcp_tw_reuse = 1`
- `net.ipv4.tcp_fin_timeout = 15`
- `net.core.rmem_max = 16777216` (16MB receive buffer)
- `net.core.wmem_max = 16777216` (16MB send buffer)

### Memory & Cache Management Sysctl
- `vm.swappiness = 10`
- `vm.vfs_cache_pressure = 50`
- `vm.dirty_background_ratio = 5`
- `vm.dirty_ratio = 10`
- `vm.compaction_proactiveness = 20`
- `vm.watermark_boost_factor = 0`
- `fs.file-max = 2097152` (High descriptor limit for Steam Proton games)

### Application Priority & Interrupt Balancing
- **Ananicy-cpp**: `services.ananicy.enable = true`, package `pkgs.ananicy-cpp`, ruleset `pkgs.ananicy-rules-cachyos`.
- **IRQ Balance**: `services.irqbalance.enable = true` (Distributes IRQs dynamically across CPU cores).

### CPU Power Scaling & GameMode
- **Governor**: Default `powersave` governor utilizing `amd_pstate=active` driver.
- **Feral GameMode** (`programs.gamemode`):
  - Renice priority: `10`
  - GPU optimizations: `apply_gpu_optimisations = "accept-responsibility"`, `amd_performance_level = "high"` (forces maximum GPU clocks during gaming).
- **LACT Daemon**: `services.lact.enable = true` (Linux AMD Control Daemon for fan curves & undervolting).
- **GameScope**: `programs.gamescope.enable = true`.

### Udev Disk I/O Schedulers
```udev
# HDD (Mechanical rotational drives) -> BFQ
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
# SATA SSD -> Kyber
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="kyber"
# NVMe SSD -> None (direct hardware submission queueing)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
```

### Global Session Environment Variables (`modules/performance.nix`)
```nix
MOZ_ENABLE_WAYLAND = "1";
MOZ_WEBRENDER = "1";
ELECTRON_OZONE_PLATFORM_HINT = "auto";
QT_QPA_PLATFORM = "wayland;xcb";
GDK_BACKEND = "wayland,x11";
SDL_VIDEODRIVER = "wayland";
CLUTTER_BACKEND = "wayland";
NH_FLAKE = "/etc/nixos";
AMD_VULKAN_ICD = "RADV";
RADV_PERFTEST = "gpa_bo,sam,nggc";
MESA_SHADER_CACHE_DIR = "/home/justkowal/.cache/mesa_shader_cache";
MESA_SHADER_CACHE_MAX_SIZE = "10G";
__GL_SHADER_DISK_CACHE = "1";
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP = "1";
```

---

## 6. Audio Architecture & PAM Realtime Limits (`modules/desktop.nix` & `hosts/desktop/configuration.nix`)

- **Audio Daemon**: PipeWire enabled with ALSA (32-bit support), PulseAudio replacement, and JACK replacement interfaces.
- **Realtime Kit**: `security.rtkit.enable = true`.
- **Low-Latency Quantum Tuning**:
  - Sample Rate: `48000 Hz`
  - Default Quantum: `64 frames` (~1.33ms latency)
  - Quantum Range: Min `32`, Max `1024`
- **PAM Limits (`security.pam.loginLimits`)**:
  - `@audio rtprio = 99`
  - `@audio memlock = unlimited`
  - `@audio nice = -19`

---

## 7. System Minimalization & Logging (`modules/systemd-minimal.nix`)

- **Systemd Timeouts**:
  - `DefaultTimeoutStartSec = "15s"`
  - `DefaultTimeoutStopSec = "10s"`
  - `DefaultDeviceTimeoutSec = "15s"`
- **Coredumps**: `systemd.coredump.enable = false` (Prevents disk/CPU spikes on program crashes).
- **OOM Daemon**: `systemd.oomd.enable = false` (Prevents unwanted process termination).
- **Journald Logging**:
  - `Storage = volatile` (Logs stored in RAM `/run/log/journal`).
  - `SystemMaxUse = 50M`, `RuntimeMaxUse = 50M`.
- **Network Online Target**: `systemd.targets.network-online.wantedBy` cleared and `NetworkManager-wait-online.enable = false` to prevent boot blocking.
