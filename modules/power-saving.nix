{
  config,
  pkgs,
  lib,
  ...
}: let
  powerModeScript = pkgs.writeShellApplication {
    name = "power-mode";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gawk
      libnotify
      procps
      systemd
    ];
    text = ''
      is_ultra() {
        if systemctl is-active --quiet ultra-power-save-runtime.service 2>/dev/null; then
          return 0
        fi
        return 1
      }

      show_status() {
        echo "═══════════════════════════════════════════════════════════"
        echo "              POWER SAVING MODE STATUS                     "
        echo "═══════════════════════════════════════════════════════════"
        if is_ultra; then
          echo "  Mode:                   [ ULTRA LOW POWER ACTIVE ]"
        else
          echo "  Mode:                   [ STANDARD / BALANCED ]"
        fi
        echo "  Active Kernel:          $(uname -r)"

        # Discharge / Battery Wattage
        if [ -f /sys/class/power_supply/BAT0/power_now ]; then
          p_now=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null || echo 0)
          watts=$(awk "BEGIN {printf \"%.2f\", $p_now / 1000000}")
          status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")
          echo "  Battery Power Draw:     $watts W ($status)"
        fi

        # CPU Governor & Boost
        gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
        boost="unknown"
        if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
          [ "$(cat /sys/devices/system/cpu/cpufreq/boost)" = "1" ] && boost="Enabled" || boost="Disabled"
        fi
        echo "  CPU Scaling Governor:   $gov"
        echo "  CPU Core Boost:         $boost"

        # SMT (Hyperthreading)
        smt="unknown"
        if [ -f /sys/devices/system/cpu/smt/control ]; then
          smt=$(cat /sys/devices/system/cpu/smt/control)
        fi
        echo "  SMT (Hyperthreading):   $smt"

        # ThinkPad Platform Profile
        profile="unknown"
        if [ -f /sys/firmware/acpi/platform_profile ]; then
          profile=$(cat /sys/firmware/acpi/platform_profile)
        fi
        echo "  Platform Profile:       $profile"

        # PCIe ASPM
        aspm="unknown"
        if [ -f /sys/module/pcie_aspm/parameters/policy ]; then
          aspm=$(cat /sys/module/pcie_aspm/parameters/policy)
        fi
        echo "  PCIe ASPM Policy:       $aspm"

        # Panel Power Savings (ABM)
        for p in /sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings; do
          if [ -f "$p" ]; then
            echo "  AMD Panel Savings(ABM): $(cat "$p")"
            break
          fi
        done
        echo "═══════════════════════════════════════════════════════════"
      }

      enable_ultra() {
        if is_ultra; then
          echo "Ultra Low Power Mode is already active."
          if command -v notify-send >/dev/null 2>&1; then
            notify-send -u low -i battery "Power Mode" "Ultra Low Power Mode is already active."
          fi
          exit 0
        fi

        echo "Switching to Ultra Low Power Specialization..."
        if [ -x /run/current-system/specialisation/ultra-low-power/bin/switch-to-configuration ]; then
          sudo /run/current-system/specialisation/ultra-low-power/bin/switch-to-configuration switch
        elif [ -x /run/booted-system/specialisation/ultra-low-power/bin/switch-to-configuration ]; then
          sudo /run/booted-system/specialisation/ultra-low-power/bin/switch-to-configuration switch
        else
          echo "Error: ultra-low-power specialization not found in /run/current-system or /run/booted-system."
          exit 1
        fi

        # Throttle Hyprland rendering overhead (disable animations, shadows & blur)
        if pgrep -x Hyprland >/dev/null 2>&1 && command -v hyprctl >/dev/null 2>&1; then
          hyprctl keyword animations:enabled 0 2>/dev/null || true
          hyprctl keyword decoration:blur:enabled 0 2>/dev/null || true
          hyprctl keyword decoration:shadow:enabled 0 2>/dev/null || true
        fi

        if command -v notify-send >/dev/null 2>&1; then
          notify-send -u normal -i battery-empty "Power Mode" "Switched to Ultra Low Power Mode\n• CPU Boost disabled & SMT parked\n• PCIe ASPM powersupersave\n• Panel ABM level 4 enabled"
        fi
        echo "Successfully activated Ultra Low Power Mode."
      }

      disable_ultra() {
        if ! is_ultra; then
          echo "Standard power mode is already active."
          if command -v notify-send >/dev/null 2>&1; then
            notify-send -u low -i battery-full "Power Mode" "Standard Power Mode is already active."
          fi
          exit 0
        fi

        echo "Switching back to Standard Configuration..."
        if [ -x /run/booted-system/bin/switch-to-configuration ]; then
          sudo /run/booted-system/bin/switch-to-configuration switch
        elif [ -x /nix/var/nix/profiles/system/bin/switch-to-configuration ]; then
          sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
        else
          echo "Error: Standard system switch-to-configuration not found."
          exit 1
        fi

        # Restore Hyprland animations, shadows & blur
        if pgrep -x Hyprland >/dev/null 2>&1 && command -v hyprctl >/dev/null 2>&1; then
          hyprctl keyword animations:enabled 1 2>/dev/null || true
          hyprctl keyword decoration:blur:enabled 1 2>/dev/null || true
          hyprctl keyword decoration:shadow:enabled 1 2>/dev/null || true
        fi

        if command -v notify-send >/dev/null 2>&1; then
          notify-send -u normal -i battery-good "Power Mode" "Restored Standard Power Mode\n• CPU Boost enabled\n• SMT enabled (all threads active)\n• Full system performance"
        fi
        echo "Successfully restored Standard Power Mode."
      }

      toggle_mode() {
        if is_ultra; then
          disable_ultra
        else
          enable_ultra
        fi
      }

      case "''${1:-status}" in
        status) show_status ;;
        ultra|enable|on) enable_ultra ;;
        default|normal|disable|off) disable_ultra ;;
        toggle) toggle_mode ;;
        *)
          echo "Usage: power-mode [status|ultra|default|toggle]"
          exit 1
          ;;
      esac
    '';
  };
in {
  environment.systemPackages = [
    pkgs.powertop
    powerModeScript
  ];

  # Passwordless privilege escalation for power mode switching via sudo
  security.sudo.extraRules = [
    {
      groups = ["wheel"];
      commands = [
        {
          command = "/run/current-system/specialisation/ultra-low-power/bin/switch-to-configuration switch";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/current-system/specialisation/ultra-low-power/bin/switch-to-configuration test";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/booted-system/specialisation/ultra-low-power/bin/switch-to-configuration switch";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/booted-system/specialisation/ultra-low-power/bin/switch-to-configuration test";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/booted-system/bin/switch-to-configuration switch";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/booted-system/bin/switch-to-configuration test";
          options = ["NOPASSWD"];
        }
        {
          command = "/nix/var/nix/profiles/system/bin/switch-to-configuration switch";
          options = ["NOPASSWD"];
        }
        {
          command = "/nix/var/nix/profiles/system/bin/switch-to-configuration test";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  # Specialization for Ultra Low Power Saving Mode
  specialisation.ultra-low-power.configuration = {
    imports = [
      ./kernel-powersave.nix
    ];

    system.nixos.tags = ["ultra-low-power"];

    # Kernel-level boot parameters for ultra-low power consumption
    boot.kernelParams = [
      # PCIe ASPM aggressive power saving (forces L1.1 and L1.2 sub-states)
      "pcie_aspm=force"
      "pcie_aspm.policy=powersupersave"

      # AMD GPU aggressive power management & panel ABM savings
      "amdgpu.aspm=1"
      "amdgpu.dpm=1"
      "amdgpu.runpm=1"
      "amdgpu.bapm=1"
      "amdgpu.abm_level=4"

      # Kernel workqueues: pack tasks onto active cores to let idle cores sleep
      "workqueue.power_efficient=1"

      # Deepest NVMe APST power states (PS4/PS5 non-operational < 5mW)
      "nvme_core.default_ps_max_latency_us=5500"

      # CPU energy policy & deepest C-states
      "cpufreq.default_governor=powersave"
      "amd_pstate.epp=power"
      "processor.max_cstate=9"
      "intel_idle.max_cstate=9"

      # Disable watchdog ticks and audit interrupts to prevent waking idle CPUs
      "nmi_watchdog=0"
      "nowatchdog"
      "audit=0"
      "skew_tick=1"
      "mem_sleep_default=deep"
    ];

    # Kernel sysctl tuning for storage and scheduler energy minimization
    boot.kernel.sysctl = {
      # Linux kernel laptop mode: flushes dirty buffers on any read so disk sleeps longer
      "vm.laptop_mode" = 5;
      # Delay dirty page writeback to disk from 5s to 60s
      "vm.dirty_writeback_centisecs" = 6000;
      "vm.dirty_expire_centisecs" = 6000;
      "vm.dirty_background_ratio" = 10;
      "vm.dirty_ratio" = 20;
      # Disable watchdog interrupts
      "kernel.nmi_watchdog" = 0;
      "kernel.watchdog" = 0;
      # Prevent timer migration between CPU cores
      "kernel.timer_migration" = 0;
      "kernel.sched_autogroup_enabled" = 0;
    };

    # PowerTOP auto-tune: automatically enables runtime PM on all PCI, USB, and audio devices
    powerManagement.powertop.enable = true;
    powerManagement.cpuFreqGovernor = lib.mkForce "powersave";

    # TLP ultra-power-saving profile
    services.tlp = {
      enable = true;
      settings = lib.mkForce {
        # CPU Frequency, Governor & Power Policies
        CPU_SCALING_GOVERNOR_ON_AC = "powersave";
        CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
        CPU_ENERGY_PERF_POLICY_ON_AC = "power";
        CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
        CPU_BOOST_ON_AC = 0;
        CPU_BOOST_ON_BAT = 0;
        CPU_MIN_PERF_ON_AC = 0;
        CPU_MAX_PERF_ON_AC = 45;
        CPU_MIN_PERF_ON_BAT = 0;
        CPU_MAX_PERF_ON_BAT = 40;

        # ThinkPad Platform Profile: Low Power EC mode (quiet fans, lower TDP)
        PLATFORM_PROFILE_ON_AC = "low-power";
        PLATFORM_PROFILE_ON_BAT = "low-power";

        # PCIe ASPM
        PCIE_ASPM_ON_AC = "powersupersave";
        PCIE_ASPM_ON_BAT = "powersupersave";

        # Device Runtime Power Management
        RUNTIME_PM_ON_AC = "auto";
        RUNTIME_PM_ON_BAT = "auto";

        # Storage Link Power Management
        SATA_LINKPWR_ON_AC = "min_power";
        SATA_LINKPWR_ON_BAT = "min_power";
        AHCI_RUNTIME_PM_ON_AC = "auto";
        AHCI_RUNTIME_PM_ON_BAT = "auto";
        AHCI_RUNTIME_PM_TIMEOUT = 15;

        # Radio & Network
        WIFI_PWR_ON_AC = "on";
        WIFI_PWR_ON_BAT = "on";
        WOL_DISABLE = "Y";

        # USB & Audio Autosuspend
        USB_AUTOSUSPEND = 1;
        USB_AUTOSUSPEND_DELAY_SEC = 2;
        SOUND_POWER_SAVE_ON_AC = 5;
        SOUND_POWER_SAVE_ON_BAT = 5;
        SOUND_POWER_SAVE_CONTROLLER = "Y";

        # AMD Radeon GPU & Adaptive Backlight Modulation (ABM)
        RADEON_DPM_PERFLVL_ON_AC = "low";
        RADEON_DPM_PERFLVL_ON_BAT = "low";
        RADEON_POWER_PROFILE_ON_AC = "low";
        RADEON_POWER_PROFILE_ON_BAT = "low";
        AMDGPU_ABM_LEVEL_ON_AC = 4;
        AMDGPU_ABM_LEVEL_ON_BAT = 4;

        # ThinkPad Battery Health Thresholds
        START_CHARGE_THRESH_BAT0 = 85;
        STOP_CHARGE_THRESH_BAT0 = 90;
      };
    };

    # Disable background pollers that repeatedly wake hardware
    services.fwupd.enable = lib.mkForce false;
    services.irqbalance.enable = lib.mkForce false;

    # Immediate runtime activation service for on-the-fly switching without reboot
    systemd.services.ultra-power-save-runtime = {
      description = "Apply Ultra Low Power Runtime Kernel & Hardware Optimizations";
      wantedBy = ["multi-user.target"];
      after = ["tlp.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.writeShellScript "apply-ultra-power" ''
          set +e
          # 1. Disable CPU Boost (caps Ryzen 4650U under 2.1 GHz)
          [ -f /sys/devices/system/cpu/cpufreq/boost ] && echo 0 > /sys/devices/system/cpu/cpufreq/boost

          # 2. Park SMT (hyperthreading) to drop core power & wakeups
          [ -f /sys/devices/system/cpu/smt/control ] && echo off > /sys/devices/system/cpu/smt/control

          # 3. ThinkPad Platform Profile to low-power
          [ -f /sys/firmware/acpi/platform_profile ] && echo low-power > /sys/firmware/acpi/platform_profile

          # 4. PCIe ASPM powersupersave
          [ -f /sys/module/pcie_aspm/parameters/policy ] && echo powersupersave > /sys/module/pcie_aspm/parameters/policy

          # 5. AMD Panel Power Savings (ABM Level 4)
          for p in /sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings; do
            [ -f "$p" ] && echo 4 > "$p" 2>/dev/null
          done

          # 6. AMD GPU DPM low performance level
          for d in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
            [ -f "$d" ] && echo low > "$d" 2>/dev/null
          done

          # 7. Workqueue power efficiency
          [ -f /sys/module/workqueue/parameters/power_efficient ] && echo 1 > /sys/module/workqueue/parameters/power_efficient

          # 8. Audio codec power saving
          for a in /sys/module/snd_*/parameters/power_save; do
            [ -f "$a" ] && echo 1 > "$a" 2>/dev/null
          done

          # 9. Autosuspend for all PCI and USB devices
          for i in /sys/bus/pci/devices/*/power/control /sys/bus/usb/devices/*/power/control; do
            [ -f "$i" ] && echo auto > "$i" 2>/dev/null
          done
          exit 0
        ''}";
        ExecStop = "${pkgs.writeShellScript "revert-ultra-power" ''
          set +e
          [ -f /sys/devices/system/cpu/cpufreq/boost ] && echo 1 > /sys/devices/system/cpu/cpufreq/boost
          [ -f /sys/devices/system/cpu/smt/control ] && echo on > /sys/devices/system/cpu/smt/control
          [ -f /sys/firmware/acpi/platform_profile ] && echo balanced > /sys/firmware/acpi/platform_profile
          [ -f /sys/module/pcie_aspm/parameters/policy ] && echo default > /sys/module/pcie_aspm/parameters/policy
          for p in /sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings; do
            [ -f "$p" ] && echo 1 > "$p" 2>/dev/null
          done
          for d in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
            [ -f "$d" ] && echo auto > "$d" 2>/dev/null
          done
          exit 0
        ''}";
      };
    };
  };
}
