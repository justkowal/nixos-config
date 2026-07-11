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
      };
    };
  in
    # Generate complete set of kernel packages (modules, etc.) for our custom kernel
    pkgs.linuxPackagesFor customKernel;
}
