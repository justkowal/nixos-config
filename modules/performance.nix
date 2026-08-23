{ config, pkgs, lib, ... }:

{
  zramSwap = { enable = true; algorithm = "lz4"; memoryPercent = 50; priority = 10; };

  services.dbus.implementation = "broker";

  boot.kernelModules = [ "tcp_bbr" ];
  boot.kernel.sysctl = {
    "net.core.default_qdisc" = "cake";
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.ipv4.tcp_slow_start_after_idle" = 0;
    "net.ipv4.tcp_tw_reuse" = 1;
    "net.ipv4.tcp_fin_timeout" = 15;
    "net.ipv4.tcp_fastopen" = 3;
    "net.ipv4.tcp_rmem" = "4096 87380 16777216";
    "net.ipv4.tcp_wmem" = "4096 65536 16777216";
    "net.ipv4.tcp_mtu_probing" = 1;
    "net.ipv4.tcp_sack" = 1;
    "net.ipv4.tcp_dsack" = 1;
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.core.netdev_max_backlog" = 16384;
    "net.ipv4.tcp_max_syn_backlog" = 8192;

    "vm.swappiness" = 180;
    "vm.vfs_cache_pressure" = 100;
    "vm.dirty_background_ratio" = 5;
    "vm.dirty_ratio" = 10;
    "vm.compaction_proactiveness" = 20;
    "vm.watermark_boost_factor" = 0;

    "fs.file-max" = 2097152;
  };

  services.ananicy = {
    enable = true;
    package = pkgs.ananicy-cpp;
    rulesProvider = pkgs.ananicy-rules-cachyos;
  };

  services.irqbalance.enable = true;

  boot.kernelParams = [
    "amd_pstate=active"
    "amd_pstate.epp=performance"
    "nmi_watchdog=0"
    "audit=0"
    "split_lock_detect=off"
    "skew_tick=1"
    "clocksource=tsc"
    "tsc=reliable"
    "quiet"
    "loglevel=3"
    "systemd.show_status=auto"
    "rd.udev.log_level=3"
    "rd.systemd.show_status=false"
    "fastboot"
    "nowatchdog"
  ];

  programs.gamemode = {
    enable = true;
    settings = {
      general.renice = 10;
      gpu = { apply_gpu_optimisations = "accept-responsibility"; amd_performance_level = "high"; };
    };
  };

  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
    ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="kyber"
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none", ATTR{queue/nomerges}="2", ATTR{queue/read_ahead_kb}="256"
  '';

  services.lact.enable = true;
  programs.gamescope.enable = true;

  environment.sessionVariables = {
    MOZ_ENABLE_WAYLAND = "1";
    MOZ_WEBRENDER = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
    QT_QPA_PLATFORM = "wayland;xcb";
    GDK_BACKEND = "wayland,x11";
    SDL_VIDEODRIVER = "wayland";
    CLUTTER_BACKEND = "wayland";
    NH_FLAKE = "/etc/nixos";

    AMD_VULKAN_ICD = "RADV";
    RADV_PERFTEST = "gpa_bo,sam,nggc,csworkgroups";

    MESA_SHADER_CACHE_DIR = "/home/justkowal/.cache/mesa_shader_cache";
    MESA_SHADER_CACHE_MAX_SIZE = "10G";
    MESA_DISK_CACHE_SINGLE_FILE = "1";
    __GL_SHADER_DISK_CACHE = "1";
    __GL_SHADER_DISK_CACHE_SKIP_CLEANUP = "1";
  };
}
