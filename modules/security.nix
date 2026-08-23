{ config, pkgs, lib, ... }:

{
  boot.kernel.sysctl = {
    # File system protection
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;
    "fs.suid_dumpable" = 0;

    # Kernel pointer restriction & BPF hardening
    "kernel.kptr_restrict" = 2;
    "kernel.sysrq" = 108; # Allow sync and reboot, block raw dump
    "kernel.unprivileged_bpf_disabled" = 1;
    "net.core.bpf_jit_harden" = 2;
    "dev.tty.ldisc_autoload" = 0;

    # Network stack hardening
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.conf.all.log_martians" = 1;
    "net.ipv4.conf.default.log_martians" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
  };

  # Blacklist obsolete/unused protocol drivers
  boot.blacklistedKernelModules = [
    "dccp"
    "sctp"
    "rds"
    "tipc"
  ];

  # PAM password quality checking (zero runtime overhead)
  security.pam.pwquality.enable = true;
}
