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
        if [ -f /run/ultra-power-mode.active ]; then
          return 0
        fi
        if systemctl is-active --quiet ultra-power-save-runtime.service 2>/dev/null; then
          return 0
        fi
        if [ -f /sys/devices/system/cpu/cpufreq/boost ] && [ "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)" = "0" ]; then
          return 0
        fi
        if [ -f /sys/firmware/acpi/platform_profile ] && [ "$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)" = "low-power" ]; then
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
        echo "Switching to Ultra Low Power Mode..."
        touch /run/ultra-power-mode.active 2>/dev/null || true

        if [ -x /run/current-system/specialisation/ultra-low-power/bin/switch-to-configuration ]; then
          sudo /run/current-system/specialisation/ultra-low-power/bin/switch-to-configuration switch 2>/dev/null || true
        elif [ -x /run/booted-system/specialisation/ultra-low-power/bin/switch-to-configuration ]; then
          sudo /run/booted-system/specialisation/ultra-low-power/bin/switch-to-configuration switch 2>/dev/null || true
        fi

        # Hardware throttling overrides
        [ -f /sys/devices/system/cpu/cpufreq/boost ] && echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
        [ -f /sys/devices/system/cpu/smt/control ] && echo off > /sys/devices/system/cpu/smt/control 2>/dev/null || true
        [ -f /sys/firmware/acpi/platform_profile ] && echo low-power > /sys/firmware/acpi/platform_profile 2>/dev/null || true
        [ -f /sys/module/pcie_aspm/parameters/policy ] && echo powersupersave > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
        for p in /sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings; do
          [ -f "$p" ] && echo 4 > "$p" 2>/dev/null || true
        done
        for d in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
          [ -f "$d" ] && echo low > "$d" 2>/dev/null || true
        done

        # Throttle Hyprland rendering overhead (disable animations, shadows & blur)
        if pgrep -x Hyprland >/dev/null 2>&1 && command -v hyprctl >/dev/null 2>&1; then
          hyprctl keyword animations:enabled 0 2>/dev/null || true
          hyprctl keyword decoration:blur:enabled 0 2>/dev/null || true
          hyprctl keyword decoration:shadow:enabled 0 2>/dev/null || true
        fi

        if command -v swayosd-client >/dev/null 2>&1; then
          swayosd-client --custom-icon battery-empty --custom-message "Power Mode: Ultra Low Power" 2>/dev/null || true
        fi
        echo "Successfully activated Ultra Low Power Mode."
      }

      disable_ultra() {
        echo "Restoring Standard / Full Performance Power Mode..."
        rm -f /run/ultra-power-mode.active 2>/dev/null || true

        # 1. Switch configuration back to standard booted profile
        if [ -x /run/booted-system/bin/switch-to-configuration ]; then
          sudo /run/booted-system/bin/switch-to-configuration switch 2>/dev/null || true
        elif [ -x /nix/var/nix/profiles/system/bin/switch-to-configuration ]; then
          sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch 2>/dev/null || true
        fi

        # 2. Re-enable CPU Core Boost (Ryzen turbo up to 4.0 GHz)
        if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
          echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || sudo sh -c 'echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null' || true
        fi

        # 3. Re-enable SMT (hyperthreading for all 12 threads)
        if [ -f /sys/devices/system/cpu/smt/control ]; then
          echo on > /sys/devices/system/cpu/smt/control 2>/dev/null || sudo sh -c 'echo on > /sys/devices/system/cpu/smt/control 2>/dev/null' || true
        fi

        # 4. ThinkPad Platform Profile: balanced
        if [ -f /sys/firmware/acpi/platform_profile ]; then
          echo balanced > /sys/firmware/acpi/platform_profile 2>/dev/null || sudo sh -c 'echo balanced > /sys/firmware/acpi/platform_profile 2>/dev/null' || true
        fi

        # 5. Energy Performance Preference (EPP)
        for e in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
          if [ -f "$e" ]; then
            echo balance_performance > "$e" 2>/dev/null || true
          fi
        done

        # 6. PCIe ASPM policy: default
        if [ -f /sys/module/pcie_aspm/parameters/policy ]; then
          echo default > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || sudo sh -c 'echo default > /sys/module/pcie_aspm/parameters/policy 2>/dev/null' || true
        fi

        # 7. AMD GPU DPM: auto
        for d in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
          if [ -f "$d" ]; then
            echo auto > "$d" 2>/dev/null || sudo sh -c "echo auto > '$d' 2>/dev/null" || true
          fi
        done

        # 8. Reload TLP standard profile
        if command -v tlp >/dev/null 2>&1; then
          sudo tlp start 2>/dev/null || true
        fi

        # 9. Restore Hyprland animations, shadows & blur
        if pgrep -x Hyprland >/dev/null 2>&1 && command -v hyprctl >/dev/null 2>&1; then
          hyprctl keyword animations:enabled 1 2>/dev/null || true
          hyprctl keyword decoration:blur:enabled 1 2>/dev/null || true
          hyprctl keyword decoration:shadow:enabled 1 2>/dev/null || true
        fi

        if command -v swayosd-client >/dev/null 2>&1; then
          swayosd-client --custom-icon battery-good --custom-message "Power Mode: Standard Balanced" 2>/dev/null || true
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

  # Allow unprivileged write access to panel power savings (ABM) for dynamic contrast/battery toggling
  systemd.tmpfiles.rules = [
    "z /sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings 0666 root root -"
    # monitor-ctl bumps to balanced while docked on ac
    "z /sys/firmware/acpi/platform_profile 0666 root root -"
  ];

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="drm", KERNEL=="card*", RUN+="${pkgs.runtimeShell} -c 'chmod a+rw /sys/class/drm/%k-*/amdgpu/panel_power_savings 2>/dev/null || true'"
  '';

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

      # AMD GPU aggressive power management & panel ABM savings (ABM 4 saves panel battery power)
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

        # AMD Radeon GPU & Adaptive Backlight Modulation (ABM 4 on battery saves ~0.5W-1.5W)
        RADEON_DPM_PERFLVL_ON_AC = "low";
        RADEON_DPM_PERFLVL_ON_BAT = "low";
        RADEON_POWER_PROFILE_ON_AC = "low";
        RADEON_POWER_PROFILE_ON_BAT = "low";
        AMDGPU_ABM_LEVEL_ON_AC = 0;
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

          # 5. AMD Panel Power Savings (ABM Level 4: active backlight reduction & pixel compensation)
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
