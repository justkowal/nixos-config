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

  # 3. TCP BBR Congestion Control (Google's high-speed TCP algorithm)
  boot.kernelModules = [ "tcp_bbr" ];
  boot.kernel.sysctl = {
    # Network queue & congestion control
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.ipv4.tcp_slow_start_after_idle" = 0;   # Keep congestion window size after idle
    "net.ipv4.tcp_tw_reuse" = 1;                 # Allow reusing TIME_WAIT sockets for fast connections
    "net.ipv4.tcp_fin_timeout" = 15;             # Close inactive sockets faster

    # System memory priority tweaks (swappiness & cache pressure)
    "vm.swappiness" = 10;                # Avoid swapping to zram unless active RAM usage is high
    "vm.vfs_cache_pressure" = 50;        # Prefer keeping inode/directory caches in memory
    "vm.dirty_background_ratio" = 5;     # Flush write buffers sooner to avoid I/O bottlenecks
    "vm.dirty_ratio" = 10;

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

  # 6. AMD P-State Active Mode scaling, Silent Boot, THP & Watchdog disable
  boot.kernelParams = [
    "amd_pstate=active"
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
}
