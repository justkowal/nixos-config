{ config, pkgs, lib, ... }:

{
  # 1. zramSwap (compressed RAM swap using zstd)
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 10;
  };

  # 2. dbus-broker (modern high-performance D-Bus daemon)
  services.dbus.implementation = "broker";

  # 3. TCP BBR Congestion Control & High-Speed Network Buffers
  boot.kernelModules = [ "tcp_bbr" ];
  boot.kernel.sysctl = {
    # Network queue & congestion control
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.ipv4.tcp_slow_start_after_idle" = 0;   # Keep congestion window size after idle
    "net.ipv4.tcp_tw_reuse" = 1;                 # Allow reusing TIME_WAIT sockets for fast connections
    "net.ipv4.tcp_fin_timeout" = 15;             # Close inactive sockets faster
    "net.core.rmem_max" = 16777216;              # High-throughput socket receive buffer
    "net.core.wmem_max" = 16777216;              # High-throughput socket send buffer

    # System memory priority tweaks (swappiness, cache pressure, proactive compaction)
    "vm.swappiness" = 10;                # Avoid swapping to zram unless active RAM usage is high
    "vm.vfs_cache_pressure" = 50;        # Prefer keeping inode/directory caches in memory
    "vm.dirty_background_ratio" = 5;     # Flush write buffers sooner to avoid I/O bottlenecks
    "vm.dirty_ratio" = 10;
    "vm.compaction_proactiveness" = 20;  # Proactively defragment RAM pages for low memory latency
    "vm.watermark_boost_factor" = 0;     # Prevent sudden kswapd CPU latency spikes

    # Maximum open files limit (essential for heavy gaming compatibility / Steam Proton)
    "fs.file-max" = 2097152;
  };

  # 4. Ananicy (Auto-Nice daemon in C++ with CachyOS rulesets for application priorities)
  services.ananicy = {
    enable = true;
    package = pkgs.ananicy-cpp;
    rulesProvider = pkgs.ananicy-rules-cachyos;
  };

  # 5. IRQ Balance (Distribute hardware interrupts across cores for CPU efficiency)
  services.irqbalance.enable = true;

  # 6. AMD P-State Active Mode scaling, TSC Timer, Silent Boot, THP & Watchdog disable
  boot.kernelParams = [
    "amd_pstate=active"
    "clocksource=tsc"
    "tsc=reliable"
    "quiet"
    "loglevel=3"
    "systemd.show_status=auto"
    "rd.udev.log_level=3"
    "rd.systemd.show_status=false"
    "fastboot"
    "nowatchdog"                       # Disables kernel watchdogs to eliminate regular polling interrupts
  ];

  # 7. Feral GameMode (auto-optimizes CPU governor and GPU clock limits for games)
  programs.gamemode = {
    enable = true;
    settings = {
      general = {
        renice = 10;
      };
      gpu = {
        apply_gpu_optimisations = "accept-responsibility";
        amd_performance_level = "high";
      };
    };
  };

  # 8. Udev I/O Scheduler Rules (Tuning disk schedulers based on storage hardware)
  services.udev.extraRules = ''
    # HDD scheduler (BFQ handles mechanical drive queuing best)
    ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
    # SATA SSD scheduler (Kyber handles SSD concurrency best)
    ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="kyber"
    # NVMe scheduler (none/no-op lets the NVMe controller do all queuing directly)
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
  '';

  # 9. LACT Daemon for GPU tuning (overclocking, fan curves, undervolting)
  services.lact.enable = true;

  # 10. Enable GameScope (compositor for games)
  programs.gamescope.enable = true;

  # 11. Global Environment Variables for instant Wayland app startup, RADV Vulkan & Mesa shader caching
  environment.sessionVariables = {
    # Wayland native execution for toolkits (bypasses Xwayland launch latency)
    MOZ_ENABLE_WAYLAND = "1";
    MOZ_WEBRENDER = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
    QT_QPA_PLATFORM = "wayland;xcb";
    GDK_BACKEND = "wayland,x11";
    SDL_VIDEODRIVER = "wayland";
    CLUTTER_BACKEND = "wayland";
    NH_FLAKE = "/etc/nixos";

    # High-performance RADV Vulkan Driver & Mesh Shader optimizations for AMD GPU
    AMD_VULKAN_ICD = "RADV";
    RADV_PERFTEST = "gpa_bo,sam,nggc";

    # High-performance Mesa GPU shader disk caching
    MESA_SHADER_CACHE_DIR = "/home/justkowal/.cache/mesa_shader_cache";
    MESA_SHADER_CACHE_MAX_SIZE = "10G";
    __GL_SHADER_DISK_CACHE = "1";
    __GL_SHADER_DISK_CACHE_SKIP_CLEANUP = "1";
  };
}
