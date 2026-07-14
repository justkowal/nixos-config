{
  config,
  pkgs,
  lib,
  ...
}: {
  # Unified Optimized & Trimmed Kernel Configuration
  boot.kernelPackages = let
    # Start from the latest XanMod kernel channel
    baseKernel = pkgs.linuxPackages_xanmod_latest.kernel;

    customKernel = baseKernel.override {
      # Use full LLVM toolchain for Kernel Link-Time Optimization (LTO)
      stdenv = pkgs.llvmPackages_latest.stdenv;

      # Suppress configuration errors caused by unreachable child options after pruning
      ignoreConfigErrors = true;

      # Target architecture compilation flags
      extraMakeFlags = [
        "KCFLAGS+=-march=znver3"
        "KCFLAGS+=-mtune=znver3"
      ];

      # Single consolidated evaluation block
      structuredExtraConfig = with lib.kernel; {
        # --- 1. COMPILER & RUNTIME OPTIMIZATIONS ---
        LTO = yes;
        LTO_CLANG = yes;
        LTO_CLANG_THIN = yes;
        MODULES = yes; # Safe base target to avoid tristate prompt loops
        NUMA = no; # Optimizes for your single-CCD Ryzen 5700X

        TRANSPARENT_HUGEPAGE = yes;
        TRANSPARENT_HUGEPAGE_ALWAYS = yes;

        # Latency & Scheduler Tuning
        HZ_1000 = yes;
        PREEMPT = yes;
        SCHED_AUTOGROUP = no;
        RCU_EXPERT = yes;
        RCU_BOOST = yes;

        # --- 2. HARDWARE SUBSYSTEM PRUNING ---

        # Disable Wireless Entirely
        WLAN = no;
        WIRELESS = no;
        CFG80211 = no;
        MAC80211 = no;

        # GPU Selection (Keep AMDGPU Only)
        DRM_AMDGPU = yes;
        DRM_I915 = no;
        DRM_NOUVEAU = no;
        DRM_RADEON = no;
        DRM_VIRTIO_GPU = no;
        DRM_VMWGFX = no;
        DRM_GMA500 = no;
        DRM_HYPERV = no;

        # Disable Virtualization Hypervisors
        HYPERVISOR_GUEST = no;
        XEN = no;
        HYPERV = no;

        # Wired Ethernet (Keep Realtek r8169 Only)
        NET_VENDOR_REALTEK = yes;
        R8169 = yes;
        NET_VENDOR_3COM = no;
        NET_VENDOR_ADAPTEC = no;
        NET_VENDOR_ALACRITECH = no;
        NET_VENDOR_ALTEON = no;
        NET_VENDOR_AMAZON = no;
        NET_VENDOR_AMD = no;
        NET_VENDOR_AQUANTIA = no;
        NET_VENDOR_ARC = no;
        NET_VENDOR_ASIX = no;
        NET_VENDOR_ATHEROS = no;
        NET_VENDOR_BROADCOM = no;
        NET_VENDOR_CADENCE = no;
        NET_VENDOR_CAVIUM = no;
        NET_VENDOR_CHELSIO = no;
        NET_VENDOR_CISCO = no;
        NET_VENDOR_CORTINA = no;
        NET_VENDOR_DEC = no;
        NET_VENDOR_DLINK = no;
        NET_VENDOR_EMULEX = no;
        NET_VENDOR_EZCHIP = no;
        NET_VENDOR_FUNGIBLE = no;
        NET_VENDOR_GOOGLE = no;
        NET_VENDOR_HUAWEI = no;
        NET_VENDOR_I825XX = no;
        NET_VENDOR_INTEL = no;
        NET_VENDOR_LITEX = no;
        NET_VENDOR_MARVELL = no;
        NET_VENDOR_MELLANOX = no;
        NET_VENDOR_MICREL = no;
        NET_VENDOR_MICROCHIP = no;
        NET_VENDOR_MICROSEMI = no;
        NET_VENDOR_MICROSOFT = no;
        NET_VENDOR_MYRI = no;
        NET_VENDOR_NATSEMI = no;
        NET_VENDOR_NETERION = no;
        NET_VENDOR_NETRONOME = no;
        NET_VENDOR_NI = no;
        NET_VENDOR_NVIDIA = no;
        NET_VENDOR_OKI = no;
        NET_VENDOR_PENSANDO = no;
        NET_VENDOR_QLOGIC = no;
        NET_VENDOR_QUALCOMM = no;
        NET_VENDOR_RENESAS = no;
        NET_VENDOR_ROCKCHIP = no;
        NET_VENDOR_SAMSUNG = no;
        NET_VENDOR_SEEQ = no;
        NET_VENDOR_SILAN = no;
        NET_VENDOR_SIS = no;
        NET_VENDOR_SOLARFLARE = no;
        NET_VENDOR_SMSC = no;
        NET_VENDOR_SOCIONEXT = no;
        NET_VENDOR_STMICRO = no;
        NET_VENDOR_SUN = no;
        NET_VENDOR_SYNOPSYS = no;
        NET_VENDOR_TEHUTI = no;
        NET_VENDOR_TI = no;
        NET_VENDOR_VIA = no;
        NET_VENDOR_WIZNET = no;
        NET_VENDOR_XILINX = no;

        # Disable Unused Communication Buses
        PCCARD = no;
        CARDBUS = no;
        INFINIBAND = no;
        HAMRADIO = no;
        CAN = no;
        ISDN = no;

        # Media Subsystem (Keep Cameras/Webcams, Drop TV/SDR Tuners)
        MEDIA_SUPPORT = yes;
        MEDIA_CAMERA_SUPPORT = yes;
        MEDIA_ANALOG_TV_SUPPORT = no;
        MEDIA_DIGITAL_TV_SUPPORT = no;
        MEDIA_RADIO_SUPPORT = no;
        MEDIA_SDR_SUPPORT = no;
        MEDIA_TEST_SUPPORT = no;

        # Core USB Support
        USB_SUPPORT = yes;
        USB = yes;
        USB_XHCI_HCD = module;
        USB_EHCI_HCD = module;
        USB_OHCI_HCD = module;
        USB_STORAGE = module;
        USB_HID = module;
        USB_HIDDEV = yes;

        # USB Serial Adapters (Statically Allowed Embedded Layouts)
        USB_SERIAL = module;
        USB_SERIAL_GENERIC = yes;
        USB_SERIAL_FTDI_SIO = module;
        USB_SERIAL_CP210X = module;
        USB_SERIAL_CH341 = module;
        USB_SERIAL_PL2303 = module;
        USB_ACM = module;

        # USB Networking
        USB_NET_DRIVERS = module;
        USB_USBNET = module;
        USB_NET_CDC_EEM = module;
        USB_NET_CDC_SUBSET = module;
        USB_NET_CDCETHER = module;
        USB_NET_AX8817X = module;
        USB_NET_AX88179_178A = module;
        USB_NET_RNDIS_HOST = module;
      };
    };
  in
    pkgs.linuxPackagesFor customKernel;

  # Runtime Sysctl/Kernel Parameters
  boot.kernelParams = [
    "mitigations=off"
    "transparent_hugepage=always"
    "preempt=full"
  ];
}
