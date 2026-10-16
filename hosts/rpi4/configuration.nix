{
  config,
  pkgs,
  lib,
  ...
}: let
  # ── Scale-to-Zero Webhook Scripts ──────────────────────────────────────
  wakeWorkerScript = pkgs.writeShellScript "wake-worker" ''
    echo 'set my_boot_target="server"' > /var/www/boot-state/boot-state.cfg
    # Desktop NIC MAC address (enp4s0) for Scale-to-Zero Wake-on-LAN
    ${pkgs.wakeonlan}/bin/wakeonlan 10:ff:e0:40:7d:6e
    echo "Worker wake signal sent (target: server)"
  '';

  wakeDesktopScript = pkgs.writeShellScript "wake-desktop" ''
    echo 'set my_boot_target="desktop"' > /var/www/boot-state/boot-state.cfg
    # Desktop NIC MAC address (enp4s0) for Scale-to-Zero Wake-on-LAN
    ${pkgs.wakeonlan}/bin/wakeonlan 10:ff:e0:40:7d:6e
    echo "Desktop wake signal sent (target: desktop)"
  '';

  wakeWolScript = pkgs.writeShellScript "wake-wol" ''
    # Desktop NIC MAC address (enp4s0) for Scale-to-Zero Wake-on-LAN
    ${pkgs.wakeonlan}/bin/wakeonlan 10:ff:e0:40:7d:6e
    echo "Direct WoL signal sent (preserve boot target)"
  '';

  resetWorkerScript = pkgs.writeShellScript "reset-worker" ''
    echo 'set my_boot_target="desktop"' > /var/www/boot-state/boot-state.cfg
    echo "Boot state reset to desktop"
  '';

  webhookConfig = pkgs.writeText "hooks.json" (builtins.toJSON ([
    {
      id = "wake-worker";
      execute-command = toString wakeWorkerScript;
      command-working-directory = "/var/www/boot-state";
    }
    {
      id = "wake-desktop";
      execute-command = toString wakeDesktopScript;
      command-working-directory = "/var/www/boot-state";
    }
    {
      id = "wake-wol";
      execute-command = toString wakeWolScript;
      command-working-directory = "/var/www/boot-state";
    }
    {
      id = "reset-worker";
      execute-command = toString resetWorkerScript;
      command-working-directory = "/var/www/boot-state";
    }
  ] ++ config.lab.webhookHooks));

  initBootState = pkgs.writeShellScript "init-boot-state" ''
    if [ ! -f /var/www/boot-state/boot-state.cfg ]; then
      echo 'set my_boot_target="desktop"' > /var/www/boot-state/boot-state.cfg
      chown webhook:webhook /var/www/boot-state/boot-state.cfg
    fi
  '';

  # Scale-to-Zero SSH Proxy & Wake Helpers
  wakeAndProxyScript = pkgs.writeShellScriptBin "wake-and-proxy" ''
    target_host="''${1:-nixos-desktop.lab}"
    target_port="''${2:-22}"

    if ! ${pkgs.netcat}/bin/nc -z -w 1 "$target_host" "$target_port" 2>/dev/null; then
      echo "Desktop is powered off (scale-to-zero)." >&2
      echo "Sending Wake-on-LAN and setting boot target to 'server'..." >&2
      ${wakeWorkerScript} >&2
      echo "Waiting for Desktop to boot and start SSH..." >&2

      start_time=$(date +%s)
      while ! ${pkgs.netcat}/bin/nc -z -w 1 "$target_host" "$target_port" 2>/dev/null; do
        elapsed=$(( $(date +%s) - start_time ))
        if [ "$elapsed" -ge 90 ]; then
          echo -e "\nTimed out waiting for Desktop to boot after 90 seconds." >&2
          exit 1
        fi
        printf "   Booting Desktop... (%ds elapsed)\r" "$elapsed" >&2
        sleep 2
      done
      echo -e "\nDesktop is online! Handing off SSH session..." >&2
    fi

    exec ${pkgs.netcat}/bin/nc "$target_host" "$target_port"
  '';

  # Interactive direct SSH bridge: `ssh sandbox@nixos-rpi4.lab`
  wakeAndBridgeScript = pkgs.writeShellScript "wake-and-bridge" ''
    target_host="nixos-desktop.lab"
    target_port="22"

    if ! ${pkgs.netcat}/bin/nc -z -w 1 "$target_host" "$target_port" 2>/dev/null; then
      echo "Desktop is powered off (scale-to-zero)."
      echo "Sending Wake-on-LAN and setting boot target to 'server'..."
      ${wakeWorkerScript}
      echo "Waiting for Desktop to boot and start SSH..."

      start_time=$(date +%s)
      while ! ${pkgs.netcat}/bin/nc -z -w 1 "$target_host" "$target_port" 2>/dev/null; do
        elapsed=$(( $(date +%s) - start_time ))
        if [ "$elapsed" -ge 90 ]; then
          echo -e "\nTimed out waiting for Desktop to boot after 90 seconds."
          exit 1
        fi
        printf "   Booting Desktop... (%ds elapsed)\r" "$elapsed"
        sleep 2
      done
      echo -e "\nDesktop is online! Launching ephemeral sandbox..."
    fi

    exec ${pkgs.openssh}/bin/ssh -tt \
      -i /home/sandbox/.ssh/id_ed25519 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -A \
      sandbox@"$target_host" "$@"
  '';
in {
  imports = [
    ./webhooks.nix
    ../../modules/locale.nix
    ../../modules/nix-settings.nix
    ../../modules/security.nix
    ../../modules/systemd-minimal.nix
    ../../modules/kanidm-client.nix
    ../../modules/lab-hosts.nix
    ./ingress.nix
    ./containers.nix
    ./apps.nix
    ../../modules/monitoring.nix
    ../../modules/fleet-health.nix
    ./monitoring.nix
    ./energy.nix
    ./sensors.nix
    ./backup-server.nix
    ./preview-ingress.nix
    ./stream-wake.nix
    ./offpeak.nix
    ./focus.nix
  ];

  # roadmap features (docs/ROADMAP.md); the rest stay off until their secrets/hardware exist
  lab.monitoring.client.enable = true;
  lab.monitoring.server.enable = true;
  lab.focus.enable = true;

  # ── Hardware: Raspberry Pi 4 (4GB) ────────────────────────────────────
  # SD image builder module imported via flake.nix — build with:
  #   nix build .#nixosConfigurations.rpi4.config.system.build.sdImage

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.kernelParams = [ "console=ttyS1,115200n8" ];
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "50%";

  hardware.enableRedistributableFirmware = true;

  # ── Argon ONE Case Fan & Power Button ─────────────────────────────────
  # Uses the upstream argononed daemon (maintained by DarkElvenAngel) via Nixpkgs'
  # native services.hardware.argonone module, enabling I2C bus and device-tree overlays.
  services.hardware.argonone.enable = true;

  # ── Front-panel OLED Dashboard ─────────────────────────────────────────
  # Drives the 128×64 monochrome I2C OLED (SSD1306/SH1106) on /dev/i2c-1.
  # Displays: hostname, clock, CPU%, RAM, disk, CPU temp, net rates, uptime, IP.
  # argonone already enables the i2c-1 bus via device-tree; we add the kernel
  # module and group access so the Python daemon can reach /dev/i2c-1 directly.
  boot.kernelModules = [ "i2c-dev" ];
  hardware.i2c.enable = true;

  systemd.services.oled-dashboard = let
    python = pkgs.python3.withPackages (ps: with ps; [
      smbus2
      pillow
      psutil
    ]);
  in {
    description = "Front-panel OLED Dashboard (128×64 SSD1306)";
    after       = [ "network-online.target" "multi-user.target" ];
    wants       = [ "network-online.target" ];
    wantedBy    = [ "multi-user.target" ];

    serviceConfig = {
      Type       = "simple";
      ExecStart  = "${python}/bin/python3 /etc/nixos/hosts/rpi4/scripts/oled-dashboard.py";
      Restart    = "on-failure";
      RestartSec = "5s";
      # i2c group owns /dev/i2c-* via udev rule below; run as root for simplicity
      User       = "root";
      Environment = [
        "OLED_I2C_BUS=1"
        "OLED_I2C_ADDR=0x3C"
        "PYTHONUNBUFFERED=1"
      ];
    };
  };

  # udev rule: grant i2c group read/write access to all I2C bus devices
  services.udev.extraRules = ''
    KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"
  '';

  # ── Networking ─────────────────────────────────────────────────────────
  networking.hostName = "nixos-rpi4";
  networking.networkmanager.enable = true;
  networking.hosts."127.0.0.1" = [
    "nixos-rpi4.lab"
    "lab"
    "home.lab"
    "bookmarks.lab"
    "docs.lab"
    "idm.lab"
    "git.lab"
    "ci.lab"
    "render.lab"
    "portfolio.lab"
    "vault.lab"
    "ntfy.lab"
    "status.lab"
    "cache.lab"
  ];

  # Kernel IP forwarding for Tailscale exit node & subnet router
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  networking.firewall = {
    enable = true;
    checkReversePath = "loose";
    trustedInterfaces = [ "tailscale0" ];
    allowedTCPPorts = [
      22    # SSH
      53    # DNS (Blocky)
      80    # HTTP (Caddy — GRUB boot-state fetch, Flamenco worker HTTP)
      443   # HTTPS (Caddy — all *.lab vhosts)
      9000  # Woodpecker gRPC (agent ↔ server)
      9100  # Webhook receiver (Scale-to-Zero wake / reset triggers)
    ];
    allowedUDPPorts = [
      53    # DNS (Blocky)
    ];
  };

  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets."tailscale_auth_key".path;
    extraUpFlags = [
      "--accept-routes"
      "--advertise-exit-node"
      "--advertise-routes=192.168.1.0/24"
    ];
  };

  programs.mosh.enable = true;

  # ── Sudo: passwordless for wheel on headless orchestrator ──────────────
  security.sudo.wheelNeedsPassword = false;

  # ── User ───────────────────────────────────────────────────────────────
  users.users.justkowal = {
    isNormalUser = true;
    description = "justkowal";
    extraGroups = [ "networkmanager" "wheel" "podman" "i2c" ];
    # SSH keys inherited cluster-wide from modules/security.nix
  };

  # Unprivileged user for the webhook receiver
  users.users.webhook = {
    isSystemUser = true;
    group = "webhook";
  };
  users.groups.webhook = {};

  # Interactive bridge user for direct `ssh sandbox@nixos-rpi4.lab`
  users.users.sandbox = {
    isNormalUser = true;
    description = "Interactive bridge to Desktop sandbox";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINq047VZyk7koA7QCAW8RuGaqu8YePnLPnOIIgo0TiBS justkowal@desktop"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG1S6Xyulmhl+KjN9oM/jsXsQlDi1I6gd9KFmkvnYV+9 justkowal@thinkpad"
    ];
  };

  environment.systemPackages = [
    wakeAndProxyScript
    (pkgs.writeShellScriptBin "wake-desktop" ''
      exec ${wakeDesktopScript}
    '')
    (pkgs.writeShellScriptBin "wake-worker" ''
      exec ${wakeWorkerScript}
    '')
    (pkgs.writeShellScriptBin "wake-wol" ''
      exec ${wakeWolScript}
    '')
    pkgs.wakeonlan
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
    extraConfig = ''
      Match User sandbox
        ForceCommand ${wakeAndBridgeScript}
        AllowTcpForwarding no
        AllowStreamLocalForwarding no
        X11Forwarding no
    '';
  };

  # Ensure Flamenco data and shared render directories exist
  systemd.tmpfiles.rules = [
    "d /var/lib/flamenco 0755 root root -"
    "d /home/justkowal/Sync/Render 0755 justkowal users -"
    "d /home/justkowal/Sync/Notes 0755 justkowal users -"
    "d /home/justkowal/Sync/GameSaves 0755 justkowal users -"
    "d /home/justkowal/Sync/Documents 0755 justkowal users -"
    "d /home/justkowal/Sync/Documents/consume 0777 justkowal users -"
    "d /var/www/boot-state 0755 webhook webhook -"
    "d /var/lib/caddy/pki 0700 caddy caddy -"
    "C /var/lib/caddy/pki/homelab-ca.crt 0644 caddy caddy - ${../../modules/certs/homelab-ca.crt}"
    "d /home/justkowal/Sync/Backups 0755 justkowal users -"
    "d /home/justkowal/Sync/Backups/forgejo 0755 git git -"
    "d /home/justkowal/Sync/Backups/state 0755 justkowal users -"
    "d /var/lib/vaultwarden 0700 vaultwarden vaultwarden -"
    "f /var/lib/vaultwarden/vaultwarden.env 0600 vaultwarden vaultwarden -"
  ];

  # ── Automated Homelab State Backup ─────────────────────────────────────
  # Takes online hot snapshots of Kanidm, Woodpecker, and Caddy PKI state.
  # Stores timestamped compressed archives in `/home/justkowal/Sync/Backups/state`.
  # Syncthing automatically replicates this folder to the Desktop's btrfs SSD.
  systemd.services.homelab-state-backup = {
    description = "Daily snapshot of Kanidm, Woodpecker, and Caddy PKI state";
    after = [ "network.target" ];
    path = [ pkgs.sqlite pkgs.gnutar pkgs.zstd pkgs.coreutils pkgs.findutils ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = pkgs.writeShellScript "homelab-state-backup" ''
        set -euo pipefail
        BACKUP_DIR="/home/justkowal/Sync/Backups/state"
        TMP_DIR=$(mktemp -d /tmp/state-backup-XXXXXX)
        DATE=$(date +%Y-%m-%d_%H%M%S)
        ARCHIVE="$BACKUP_DIR/homelab-state-$DATE.tar.zst"

        mkdir -p "$BACKUP_DIR" "$TMP_DIR"

        # 1. Hot-backup Kanidm DB if running
        if [ -f /var/lib/kanidm/kanidm.db ]; then
          mkdir -p "$TMP_DIR/kanidm"
          sqlite3 /var/lib/kanidm/kanidm.db ".backup $TMP_DIR/kanidm/kanidm.db"
          cp -r /var/lib/kanidm/*.pem "$TMP_DIR/kanidm/" 2>/dev/null || true
        fi

        # 2. Hot-backup Woodpecker DB if running
        if [ -f /var/lib/woodpecker-server/woodpecker.sqlite ]; then
          mkdir -p "$TMP_DIR/woodpecker"
          sqlite3 /var/lib/woodpecker-server/woodpecker.sqlite ".backup $TMP_DIR/woodpecker/woodpecker.sqlite"
        fi

        # 3. Backup Caddy PKI / CA keys if present
        if [ -d /var/lib/caddy/pki ]; then
          mkdir -p "$TMP_DIR/caddy-pki"
          cp -r /var/lib/caddy/pki/* "$TMP_DIR/caddy-pki/" 2>/dev/null || true
        fi

        # 4. Backup Vaultwarden DB & keys if present
        if [ -d /var/lib/vaultwarden ]; then
          mkdir -p "$TMP_DIR/vaultwarden"
          if [ -f /var/lib/vaultwarden/db.sqlite3 ]; then
            sqlite3 /var/lib/vaultwarden/db.sqlite3 ".backup $TMP_DIR/vaultwarden/db.sqlite3"
          fi
          cp -r /var/lib/vaultwarden/rsa_key* "$TMP_DIR/vaultwarden/" 2>/dev/null || true
        fi

        # 5. Pack into zstd archive
        tar -C "$TMP_DIR" -c . | zstd -19 -o "$ARCHIVE"
        rm -rf "$TMP_DIR"

        chown -R justkowal:users "$BACKUP_DIR"
        chmod 0600 "$ARCHIVE"

        # 6. Prune backups older than 14 days
        find "$BACKUP_DIR" -type f -name "homelab-state-*.tar.zst" -mtime +14 -delete
        echo "State backup completed: $ARCHIVE"
        curl -s -d "Homelab state backup completed: homelab-state-$DATE.tar.zst" -H "Title: Backup" -H "Tags: white_check_mark" http://localhost:2586/alerts 2>/dev/null || true
      '';
    };
  };

  systemd.timers.homelab-state-backup = {
    description = "Daily timer for homelab state backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "03:30";
      Persistent = true;
    };
  };

  # ── Declarative Secrets Management (sops-nix) ──────────────────────────
  # Decrypts secrets at runtime using the host's SSH ed25519 host key.
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    defaultSopsFormat = "yaml";
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    validateSopsFiles = false;
    secrets."tailscale_auth_key" = {};
    secrets."cloudflare_tunnel_credentials" = {};
    secrets."harmonia_signing_key" = {};
    secrets."woodpecker_agent_secret" = {};
    secrets."woodpecker_gitea_client" = {};
    secrets."woodpecker_gitea_secret" = {};
    templates."woodpecker-server.env".content = ''
      WOODPECKER_AGENT_SECRET=${config.sops.placeholder."woodpecker_agent_secret"}
      WOODPECKER_GITEA_CLIENT=${config.sops.placeholder."woodpecker_gitea_client"}
      WOODPECKER_GITEA_SECRET=${config.sops.placeholder."woodpecker_gitea_secret"}
    '';
  };

  # ── Scale-to-Zero Webhook Receiver ─────────────────────────────────────
  # Endpoints (Tailnet-only — authenticated by Tailscale network boundary):
  #   POST http://nixos-rpi4.lab:9100/hooks/wake-worker
  #     → writes boot_target=server, sends WoL magic packet to Desktop
  #   POST http://nixos-rpi4.lab:9100/hooks/reset-worker
  #     → reverts boot_target=desktop for next manual boot
  #
  # Wire Forgejo/Woodpecker webhooks to http://nixos-rpi4.lab:9100/hooks/wake-worker
  # to auto-wake the Desktop when code is pushed or a CI pipeline triggers.
  systemd.services.webhook-receiver = {
    description = "Scale-to-zero webhook receiver";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
      User = "webhook";
      Group = "webhook";
      ExecStartPre = "+${initBootState}";
      ExecStart = "${pkgs.webhook}/bin/webhook -hooks ${webhookConfig} -port 9100 -verbose";
    };
  };

  # ── Memory Optimisation ────────────────────────────────────────────────
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  system.stateVersion = "26.05";
}

