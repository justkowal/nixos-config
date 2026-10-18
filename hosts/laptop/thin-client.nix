# Thin client mode: a battery first boot entry where this laptop only shows the desktop.
#
# A separate configuration (specialisation with inheritParentConfig = false), not the normal laptop with
# things switched off: it shares the disk, the identity (hostname, Tailscale node, user) and the boot
# chain, and nothing else. See docs/THIN_CLIENT.md.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  user = "justkowal";
  directStream = pkgs.writeShellApplication {
    name = "thin-direct-stream";
    runtimeInputs = [pkgs.moonlight-qt pkgs.wakeonlan];
    text = ''
      export QT_QPA_PLATFORM=eglfs
      export QT_QPA_EGLFS_INTEGRATION=eglfs_kms
      export QT_QPA_EGLFS_KMS_ATOMIC=1
      wakeonlan 10:ff:e0:40:7d:6e >/dev/null || true
      # the desktop needs a moment to wake, Moonlight retries while it boots
      for _ in $(seq 1 60); do
        if moonlight stream nixos-desktop.lab Desktop; then exit 0; fi
        sleep 3
      done
    '';
  };
in {
  imports = [
    inputs.lanzaboote.nixosModules.lanzaboote
    inputs.home-manager.nixosModules.home-manager
    ./hardware-configuration.nix
    ../../modules/boot.nix
    ../../modules/locale.nix
    ../../modules/nix-settings.nix
    ../../modules/lab-hosts.nix
    ../../modules/lab-greeter.nix
    # the lean, tickless, low power kernel the ultra-low-power profile already builds
    ../../modules/kernel-powersave.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfree = true;
  hardware.enableRedistributableFirmware = true;
  system.nixos.tags = ["thin-client"];
  system.stateVersion = "26.05";

  # ── identity, boot chain and disk are the laptop's own ───────────────────
  networking.hostName = "thinkpad-t14s-gen1-amd";
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.timeout = 0;
  security.protectKernelImage = true;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
    settings.editor = false;
  };
  security.tpm2.enable = true;

  # ── the few services there are ───────────────────────────────────────────
  networking.networkmanager = {
    enable = true;
    wifi.powersave = true;
  };
  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
  };
  services.tailscale = {
    enable = true;
    extraUpFlags = ["--accept-routes"];
    # Taildrop and `lab run` talk to the daemon as the user
    extraSetFlags = ["--operator=${user}"];
  };
  services.upower.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
  security.rtkit.enable = true;
  security.polkit.enable = true;
  hardware.graphics.enable = true;
  hardware.bluetooth.enable = false;
  services.printing.enable = false;
  services.fwupd.enable = false;
  documentation.enable = false;

  users.users.${user} = {
    isNormalUser = true;
    description = user;
    extraGroups = ["networkmanager" "wheel" "video" "render" "audio" "input"];
  };

  # ── login: the shared greeter, then the smallest compositor that runs labd ─
  programs.labwc.enable = true;
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = builtins.replaceStrings ["--cmd Hyprland"] ["--cmd labwc --sessions /run/current-system/sw/share/wayland-sessions:/etc/lab/sessions"] config.lab.greeter.command;
      user = "greeter";
    };
  };
  # A second login entry that needs no compositor at all: Moonlight draws straight to the screen through
  # KMS (Qt EGLFS), and its DRM renderer puts decoded frames on a display plane. Pick it in the greeter.
  environment.etc."lab/sessions/stream-direct.desktop".text = ''
    [Desktop Entry]
    Name=Stream direct (no compositor)
    Exec=${directStream}/bin/thin-direct-stream
    Type=Application
  '';

  fonts.packages = [pkgs.inter pkgs.departure-mono pkgs.nerd-fonts.jetbrains-mono];
  environment.systemPackages = with pkgs; [moonlight-qt foot wl-clipboard brightnessctl libnotify wakeonlan libva-utils];

  # ── battery: every knob of the ultra-low-power profile, applied for good ─
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "suspend";
    HandleLidSwitchDocked = "suspend";
  };
  boot.kernelParams = [
    "pcie_aspm=force"
    "pcie_aspm.policy=powersupersave"
    "amdgpu.aspm=1"
    "amdgpu.dpm=1"
    "amdgpu.runpm=1"
    "amdgpu.bapm=1"
    "amdgpu.abm_level=4"
    "workqueue.power_efficient=1"
    "nvme_core.default_ps_max_latency_us=5500"
    "cpufreq.default_governor=powersave"
    "amd_pstate.epp=power"
    "nmi_watchdog=0"
    "nowatchdog"
    "audit=0"
    "skew_tick=1"
    "mem_sleep_default=deep"
  ];
  boot.kernel.sysctl = {
    "vm.laptop_mode" = 5;
    "vm.dirty_writeback_centisecs" = 6000;
    "vm.dirty_expire_centisecs" = 6000;
    "kernel.nmi_watchdog" = 0;
    "kernel.watchdog" = 0;
    "kernel.timer_migration" = 0;
    "kernel.sched_autogroup_enabled" = 0;
  };
  powerManagement.enable = true;
  powerManagement.cpuFreqGovernor = lib.mkForce "powersave";
  powerManagement.powertop.enable = true;
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "powersave";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC = "power";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      CPU_BOOST_ON_AC = 0;
      CPU_BOOST_ON_BAT = 0;
      PLATFORM_PROFILE_ON_AC = "low-power";
      PLATFORM_PROFILE_ON_BAT = "low-power";
      PCIE_ASPM_ON_AC = "powersupersave";
      PCIE_ASPM_ON_BAT = "powersupersave";
      RUNTIME_PM_ON_AC = "auto";
      RUNTIME_PM_ON_BAT = "auto";
      WIFI_PWR_ON_AC = "on";
      WIFI_PWR_ON_BAT = "on";
      USB_AUTOSUSPEND = 1;
      SOUND_POWER_SAVE_ON_AC = 5;
      SOUND_POWER_SAVE_ON_BAT = 5;
      AMDGPU_ABM_LEVEL_ON_BAT = 4;
      START_CHARGE_THRESH_BAT0 = 85;
      STOP_CHARGE_THRESH_BAT0 = 90;
    };
  };

  # ── the desk, drawn by labd ──────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {laptop = true;};
    users.${user} = import ../../home/thin.nix;
  };
}
