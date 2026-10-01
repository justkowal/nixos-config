{...}: {
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 35;
    priority = 10;
  };

  services.dbus.implementation = "broker";
  services.irqbalance.enable = true;
  services.fwupd.enable = true;

  boot.kernelParams = [
    "amd_pstate=active"
    "amd_pstate.epp=balance_power"
    "quiet"
    "loglevel=3"
    "systemd.show_status=auto"
    "rd.udev.log_level=3"
    "rd.systemd.show_status=false"
  ];

  boot.kernel.sysctl = {
    "vm.swappiness" = 80;
    "vm.vfs_cache_pressure" = 50;
  };

  powerManagement.cpuFreqGovernor = "powersave";
}
