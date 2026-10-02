{
  config,
  pkgs,
  lib,
  inputs ? null,
  ...
}: let
  # Use pinned nixpkgs-kernel to isolate the power-saving kernel from general package updates
  kernelPkgs =
    if inputs ? nixpkgs-kernel && inputs.nixpkgs-kernel != null
    then inputs.nixpkgs-kernel.legacyPackages.${pkgs.stdenv.hostPlatform.system}
    else pkgs;

  # Base kernel: Mainline/latest Linux with modern AMD P-State, EAS energy models, and TEO idle governor
  baseKernel = kernelPkgs.linuxPackages_latest.kernel;

  customKernel =
    (baseKernel.override {
      stdenv = kernelPkgs.llvmPackages_latest.stdenv;
      ignoreConfigErrors = true;

      structuredExtraConfig = lib.mapAttrs (_: v: lib.mkForce v) (with lib.kernel; {
        # Clang ThinLTO: Reduces binary size and optimizes register allocation for instruction cache efficiency
        LTO = yes;
        LTO_CLANG = yes;
        LTO_CLANG_THIN = yes;
        MODULES = yes;

        # -------------------------------------------------------------
        # Timer Frequency & Tickless Idle (Core Power Saving)
        # -------------------------------------------------------------
        # 100 Hz timer frequency: drops timer interrupts down to 100/sec (10ms tick window),
        # reducing CPU wakeups by up to 90% compared to 1000 Hz, maximizing deep C-state residency
        HZ_100 = yes;

        # Dynamic Tickless Idle: stops timer ticks completely when CPU cores are idle
        NO_HZ = yes;
        NO_HZ_IDLE = yes;
        NO_HZ_FULL = no;
        HIGH_RES_TIMERS = yes;

        # -------------------------------------------------------------
        # Preemption & Energy-Aware Scheduler (EAS)
        # -------------------------------------------------------------
        # Voluntary preemption minimizes context-switch interrupts while maintaining smooth UI
        PREEMPT_VOLUNTARY = yes;

        # Scheduler power awareness: multi-core and SMT topology packing
        SCHED_SMT = yes;
        SCHED_MC = yes;
        SCHED_MC_PRIO = yes;
        SCHED_CLUSTER = yes;

        # Linux Energy Model framework: provides power cost tables to CFS/EEVDF to choose energy-optimal cores
        ENERGY_MODEL = yes;

        # CPU Frequency Scaling & Governors
        CPU_FREQ = yes;
        CPU_FREQ_STAT = yes;
        CPU_FREQ_GOV_SCHEDUTIL = yes;
        CPU_FREQ_GOV_POWERSAVE = yes;

        # CPU Idle Governors: TEO (Timer Events Oriented) optimized for mobile battery life
        CPU_IDLE = yes;
        CPU_IDLE_GOV_TEO = yes;
        CPU_IDLE_GOV_MENU = yes;
        HALTPOLL_CPUIDLE = no; # Avoid busy-wait haltpolling that burns battery

        # -------------------------------------------------------------
        # RCU (Read-Copy Update) Power Optimization
        # -------------------------------------------------------------
        # Accelerates RCU grace periods and offloads callbacks so idle CPUs can sleep immediately
        RCU_FAST_NO_HZ = yes;
        RCU_NOCB_CPU = yes;
        RCU_BOOST = no;
        RCU_EXPERT = yes;

        # -------------------------------------------------------------
        # AMD APU & Platform Power Management (ThinkPad AMD Zen 2 Renoir)
        # -------------------------------------------------------------
        X86_AMD_PSTATE = yes;
        X86_AMD_PSTATE_DEFAULT_UT = yes;

        # -------------------------------------------------------------
        # Bus, PCIe & Device Power Management
        # -------------------------------------------------------------
        PM = yes;
        PM_SLEEP = yes;
        PM_AUTOSLEEP = yes;
        PM_WAKELOCKS = yes;
        PCIEASPM = yes;
        PCIEASPM_POWER_SUPERSAVE = yes; # Aggressively forces PCIe L1.1 and L1.2 sub-states
        DPM_WATCHDOG = no;

        # Storage link power management (min_power DIPM/HIPM)
        SATA_MOBILE_LPM_POLICY = freeform "4";
        BLK_DEV_NVME = yes;
        NVME_MULTIPATH = no;

        # Wireless 802.11 power saving enabled by default at kernel level
        CFG80211_DEFAULT_PS = yes;

        # Transparent hugepages in madvise mode (saves page table overhead without fragmentation)
        TRANSPARENT_HUGEPAGE = yes;
        TRANSPARENT_HUGEPAGE_ALWAYS = no;
        TRANSPARENT_HUGEPAGE_MADVISE = yes;

        # -------------------------------------------------------------
        # Subsystem Pruning (Reduce kernel binary & resident memory footprint)
        # -------------------------------------------------------------
        # AMD iGPU only — strip all foreign GPU drivers
        DRM_AMDGPU = yes;
        DRM_I915 = no;
        DRM_NOUVEAU = no;
        DRM_RADEON = no;
        DRM_VIRTIO_GPU = no;
        DRM_VMWGFX = no;
        DRM_GMA500 = no;
        DRM_HYPERV = no;

        # Strip hypervisor guest drivers on bare metal laptop
        HYPERVISOR_GUEST = no;
        XEN = no;
        HYPERV = no;
        KVM_GUEST = no;

        # Strip server NUMA overhead (single Renoir APU)
        NUMA = no;

        # Keep essential laptop USB, input & camera hardware
        MEDIA_SUPPORT = yes;
        MEDIA_CAMERA_SUPPORT = yes;
        USB_SUPPORT = yes;
        USB = yes;
        USB_XHCI_HCD = module;
        USB_STORAGE = module;
        USB_HID = module;
        USB_HIDDEV = yes;
      });
    }).overrideAttrs (oldAttrs: {
      env =
        (oldAttrs.env or {})
        // {
          # -O2 for instruction cache compactness and reduced memory bus power draw, tuned for Zen 2
          KCFLAGS = "-O2 -march=znver2 -mtune=znver2 -fno-semantic-interposition";
        };
    });
in {
  boot.kernelPackages = lib.mkForce (kernelPkgs.linuxPackagesFor customKernel);

  boot.kernelParams = [
    "amd_pstate=active"
    "amd_pstate.epp=power"
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
    "processor.max_cstate=9"
    "intel_idle.max_cstate=9"
    "nmi_watchdog=0"
    "nowatchdog"
    "audit=0"
    "skew_tick=1"
    "mem_sleep_default=deep"
    "transparent_hugepage=madvise"
    "preempt=voluntary"
  ];
}
