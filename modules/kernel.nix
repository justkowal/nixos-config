{ config, pkgs, lib, ... }:

{
  boot.kernelPackages = let
    baseKernel = pkgs.linuxPackages_xanmod_latest.kernel;

    customKernel = baseKernel.override {
      stdenv = pkgs.llvmPackages_latest.stdenv;
      ignoreConfigErrors = true;

      # Zen 3 (5700X) tuned compilation
      extraMakeFlags = [ "KCFLAGS+=-O3 -march=znver3 -mtune=znver3 -fno-semantic-interposition" ];

      structuredExtraConfig = with lib.kernel; {
        # Clang ThinLTO
        LTO = yes;
        LTO_CLANG = yes;
        LTO_CLANG_THIN = yes;
        MODULES = yes;
        NUMA = no; # Single-CCD Ryzen, no NUMA topology

        TRANSPARENT_HUGEPAGE = yes;
        TRANSPARENT_HUGEPAGE_ALWAYS = yes;

        # Low-latency scheduler
        HZ_1000 = yes;
        PREEMPT = yes;
        SCHED_AUTOGROUP = no;
        FAIR_GROUP_SCHED = no;
        RCU_EXPERT = yes;
        RCU_BOOST = yes;

        # No wireless hardware on desktop
        WLAN = no; WIRELESS = no; CFG80211 = no; MAC80211 = no;

        # AMDGPU only
        DRM_AMDGPU = yes;
        DRM_I915 = no; DRM_NOUVEAU = no; DRM_RADEON = no;
        DRM_VIRTIO_GPU = no; DRM_VMWGFX = no; DRM_GMA500 = no; DRM_HYPERV = no;

        # No hypervisors on bare metal
        HYPERVISOR_GUEST = no; XEN = no; HYPERV = no;

        # Realtek r8169 only
        NET_VENDOR_REALTEK = yes; R8169 = yes;
        NET_VENDOR_3COM = no; NET_VENDOR_ADAPTEC = no; NET_VENDOR_ALACRITECH = no;
        NET_VENDOR_ALTEON = no; NET_VENDOR_AMAZON = no; NET_VENDOR_AMD = no;
        NET_VENDOR_AQUANTIA = no; NET_VENDOR_ARC = no; NET_VENDOR_ASIX = no;
        NET_VENDOR_ATHEROS = no; NET_VENDOR_BROADCOM = no; NET_VENDOR_CADENCE = no;
        NET_VENDOR_CAVIUM = no; NET_VENDOR_CHELSIO = no; NET_VENDOR_CISCO = no;
        NET_VENDOR_CORTINA = no; NET_VENDOR_DEC = no; NET_VENDOR_DLINK = no;
        NET_VENDOR_EMULEX = no; NET_VENDOR_EZCHIP = no; NET_VENDOR_FUNGIBLE = no;
        NET_VENDOR_GOOGLE = no; NET_VENDOR_HUAWEI = no; NET_VENDOR_I825XX = no;
        NET_VENDOR_INTEL = no; NET_VENDOR_LITEX = no; NET_VENDOR_MARVELL = no;
        NET_VENDOR_MELLANOX = no; NET_VENDOR_MICREL = no; NET_VENDOR_MICROCHIP = no;
        NET_VENDOR_MICROSEMI = no; NET_VENDOR_MICROSOFT = no; NET_VENDOR_MYRI = no;
        NET_VENDOR_NATSEMI = no; NET_VENDOR_NETERION = no; NET_VENDOR_NETRONOME = no;
        NET_VENDOR_NI = no; NET_VENDOR_NVIDIA = no; NET_VENDOR_OKI = no;
        NET_VENDOR_PENSANDO = no; NET_VENDOR_QLOGIC = no; NET_VENDOR_QUALCOMM = no;
        NET_VENDOR_RENESAS = no; NET_VENDOR_ROCKCHIP = no; NET_VENDOR_SAMSUNG = no;
        NET_VENDOR_SEEQ = no; NET_VENDOR_SILAN = no; NET_VENDOR_SIS = no;
        NET_VENDOR_SOLARFLARE = no; NET_VENDOR_SMSC = no; NET_VENDOR_SOCIONEXT = no;
        NET_VENDOR_STMICRO = no; NET_VENDOR_SUN = no; NET_VENDOR_SYNOPSYS = no;
        NET_VENDOR_TEHUTI = no; NET_VENDOR_TI = no; NET_VENDOR_VIA = no;
        NET_VENDOR_WIZNET = no; NET_VENDOR_XILINX = no;

        # Unused buses
        PCCARD = no; CARDBUS = no; INFINIBAND = no;
        HAMRADIO = no; CAN = no; ISDN = no;

        # Keep cameras, drop TV/radio tuners
        MEDIA_SUPPORT = yes; MEDIA_CAMERA_SUPPORT = yes;
        MEDIA_ANALOG_TV_SUPPORT = no; MEDIA_DIGITAL_TV_SUPPORT = no;
        MEDIA_RADIO_SUPPORT = no; MEDIA_SDR_SUPPORT = no; MEDIA_TEST_SUPPORT = no;

        # USB
        USB_SUPPORT = yes; USB = yes;
        USB_XHCI_HCD = module; USB_EHCI_HCD = module; USB_OHCI_HCD = module;
        USB_STORAGE = module; USB_HID = module; USB_HIDDEV = yes;

        # USB serial (embedded dev boards)
        USB_SERIAL = module; USB_SERIAL_GENERIC = yes;
        USB_SERIAL_FTDI_SIO = module; USB_SERIAL_CP210X = module;
        USB_SERIAL_CH341 = module; USB_SERIAL_PL2303 = module; USB_ACM = module;

        # USB networking
        USB_NET_DRIVERS = module; USB_USBNET = module;
        USB_NET_CDC_EEM = module; USB_NET_CDC_SUBSET = module;
        USB_NET_CDCETHER = module; USB_NET_AX8817X = module;
        USB_NET_AX88179_178A = module; USB_NET_RNDIS_HOST = module;
      };
    };
  in
    pkgs.linuxPackagesFor customKernel;

  boot.kernelParams = [
    "mitigations=off"
    "transparent_hugepage=always"
    "preempt=full"
  ];
}
