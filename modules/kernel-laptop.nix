{
  config,
  pkgs,
  lib,
  inputs ? null,
  ...
}: let
  # Use pinned nixpkgs-kernel to isolate the laptop kernel from general package updates
  kernelPkgs =
    if inputs ? nixpkgs-kernel && inputs.nixpkgs-kernel != null
    then inputs.nixpkgs-kernel.legacyPackages.${pkgs.stdenv.hostPlatform.system}
    else pkgs;

  baseKernel = kernelPkgs.linuxPackages_xanmod_latest.kernel;

  customKernel =
    (baseKernel.override {
      stdenv = kernelPkgs.llvmPackages_latest.stdenv;
      ignoreConfigErrors = true;

      structuredExtraConfig = with lib.kernel; {
        # Clang ThinLTO
        LTO = yes;
        LTO_CLANG = yes;
        LTO_CLANG_THIN = yes;
        MODULES = yes;

        X86_AMD_PSTATE = yes;

        TRANSPARENT_HUGEPAGE = yes;
        TRANSPARENT_HUGEPAGE_ALWAYS = no;
        TRANSPARENT_HUGEPAGE_MADVISE = yes;

        # Keep responsiveness without desktop-only over-pruning
        HZ_300 = yes;
        PREEMPT_VOLUNTARY = yes;
        SCHED_AUTOGROUP = yes;
        FAIR_GROUP_SCHED = yes;
        RCU_EXPERT = yes;
        RCU_BOOST = yes;

        # Laptop needs wireless support
        WLAN = yes;
        WIRELESS = yes;
        CFG80211 = yes;
        MAC80211 = yes;

        # AMD iGPU only
        DRM_AMDGPU = yes;
        DRM_I915 = no;
        DRM_NOUVEAU = no;
        DRM_RADEON = no;
        DRM_VIRTIO_GPU = no;
        DRM_VMWGFX = no;
        DRM_GMA500 = no;
        DRM_HYPERV = no;

        # No hypervisors on bare metal laptop
        HYPERVISOR_GUEST = no;
        XEN = no;
        HYPERV = no;

        # Keep common laptop USB and camera support
        MEDIA_SUPPORT = yes;
        MEDIA_CAMERA_SUPPORT = yes;
        USB_SUPPORT = yes;
        USB = yes;
        USB_XHCI_HCD = module;
        USB_STORAGE = module;
        USB_HID = module;
        USB_HIDDEV = yes;
      };
    }).overrideAttrs (oldAttrs: {
      env =
        (oldAttrs.env or {})
        // {
          KCFLAGS = "-O3 -march=znver2 -mtune=znver2 -fno-semantic-interposition";
        };
    });
in {
  boot.kernelPackages = kernelPkgs.linuxPackagesFor customKernel;

  boot.kernelParams = [
    "amd_pstate=active"
    "amd_pstate.epp=power"
    "transparent_hugepage=madvise"
    "preempt=full"
  ];
}
