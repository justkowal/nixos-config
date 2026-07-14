{ config, pkgs, lib, ... }:

{
  # Custom kernel packages override
  boot.kernelPackages = let
    # Start from the latest XanMod kernel channel (optimized for latency & desktop scheduling)
    baseKernel = pkgs.linuxPackages_xanmod_latest.kernel;

    # Apply the custom overrides
    customKernel = baseKernel.override {
      # Use Clang and LLVM tools (required for Kernel LTO)
      stdenv = pkgs.llvmPackages_latest.stdenv;

      # Enable specific CPU flags and compile-time optimization
      extraMakeFlags = [
        "KCFLAGS+=-march=znver3"
        "KCFLAGS+=-mtune=znver3"
        "KCFLAGS+=-O3"
      ];

      # Kernel configuration flags
      structuredExtraConfig = with lib.kernel; {
        # Link Time Optimization (LTO) via Clang
        LTO = yes;
        LTO_CLANG = yes;
        LTO_CLANG_THIN = yes;

        # Compile statically (disable loadable modules, building drivers directly in)
        MODULES = no;

        # Desktop responsiveness tweaks (1000Hz ticks + full preemption)
        HZ_1000 = yes;
        PREEMPT = yes;

        # --- MINIMAL KERNEL OPTIMIZATIONS (Disable Unused Drivers/Subsystems) ---

        # 1. Disable Wireless Core and Wi-Fi drivers (system uses ethernet only)
        WLAN = no;
        WIRELESS = no;
        CFG80211 = no;
        MAC80211 = no;

        # 2. Disable Graphics Drivers (Keep AMDGPU only)
        DRM_AMDGPU = yes;
        DRM_I915 = no;
        DRM_NOUVEAU = no;
        DRM_RADEON = no;
        DRM_VIRTIO_GPU = no;
        DRM_VMWGFX = no;
        DRM_GMA500 = no;
        DRM_HYPERV = no;

        # 3. Disable Virtualization Hypervisors (System runs on bare metal)
        HYPERVISOR_GUEST = no;
        XEN = no;
        HYPERV = no;

        # 4. Disable Unused Filesystems (Root is bcachefs, Boot is vfat)
        BTRFS_FS = no;
        XFS_FS = no;
        F2FS_FS = no;
        JFS_FS = no;
        REISERFS_FS = no;
        NFS_FS = no;
        CIFS = no;

        # 5. Disable Non-Realtek Ethernet Vendors
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

        # 6. Disable Unused Communication/Hardware Buses
        PCCARD = no;
        CARDBUS = no;
        INFINIBAND = no;
        HAMRADIO = no;
        CAN = no;
        ISDN = no;

        # 7. Disable TV/Radio/SDR (Keep camera/webcam support)
        MEDIA_SUPPORT = yes;
        MEDIA_CAMERA_SUPPORT = yes;
        MEDIA_ANALOG_TV_SUPPORT = no;
        MEDIA_DIGITAL_TV_SUPPORT = no;
        MEDIA_RADIO_SUPPORT = no;
        MEDIA_SDR_SUPPORT = no;
        MEDIA_TEST_SUPPORT = no;
      };
    };
  in
    # Generate complete set of kernel packages (modules, etc.) for our custom kernel
    pkgs.linuxPackagesFor customKernel;
}
