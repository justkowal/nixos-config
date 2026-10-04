{ config, pkgs, lib, ... }:

{
  boot.kernel.sysctl = {
    # File system protection
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;
    "fs.suid_dumpable" = 0;

    # Kernel pointer restriction, dmesg & ptrace hardening
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.yama.ptrace_scope" = 1;
    "kernel.sysrq" = 108; # Allow sync and reboot, block raw dump
    "dev.tty.ldisc_autoload" = 0;

    # eBPF: allow unprivileged BPF for rootless Podman/Netavark container bridging
    "kernel.unprivileged_bpf_disabled" = 0;
    "net.core.bpf_jit_harden" = 1;

    # Network stack hardening
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
    "net.ipv4.tcp_rfc1337" = 1;

    # Loose-mode reverse path filtering for Tailscale mesh routing
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
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

  # ── Cluster PKI & Trusted Root CA ─────────────────────────────────────
  # Automatically populates every node's system-wide trust store (OpenSSL,
  # GnuTLS, curl, browsers, Git) with the Homelab Internal Root CA.
  # Guarantees seamless, warning-free HTTPS for all `*.lab` services.
  security.pki.certificates = [
    (builtins.readFile ./certs/homelab-ca.crt)
  ];

  # ── Cluster-wide Authorized SSH Keys ──────────────────────────────────
  # Guarantees seamless key-based SSH access across all machines (Desktop,
  # Laptop, RPi4) without password prompts.
  users.users.justkowal.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINq047VZyk7koA7QCAW8RuGaqu8YePnLPnOIIgo0TiBS justkowal@desktop"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG1S6Xyulmhl+KjN9oM/jsXsQlDi1I6gd9KFmkvnYV+9 justkowal@thinkpad"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFWMDlHUXnZP+8GHiZ9qGUrWs1SKDk0t7pbzQjDus5T9 github-actions-deploy-talented"
  ];
}
