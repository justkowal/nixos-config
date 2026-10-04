{
  config,
  pkgs,
  lib,
  ...
}: let
  # ── Flamenco Manager — built from source (upstream does not provide arm64 binaries)
  flamenco = pkgs.callPackage ../../pkgs/flamenco { };


  flamencoManagerConfig = pkgs.writeText "flamenco-manager.yaml" ''
    _meta:
      version: 3
    manager_name: homelab-render
    shared_storage_path: /data/shared-storage
    listen: :8080
    local_manager_storage_path: /data
  '';

  # ponytail: no official Flamenco OCI image — built from upstream binary via dockerTools
  flamencoManagerImage = pkgs.dockerTools.buildImage {
    name = "flamenco-manager";
    tag = "local";
    copyToRoot = pkgs.buildEnv {
      name = "flamenco-manager-root";
      paths = [ flamenco pkgs.cacert ];
    };
    config = {
      Cmd = [ "/bin/flamenco-manager" ];
      WorkingDir = "/data";
    };
  };

  # ── Scale-to-Zero Webhook Scripts ──────────────────────────────────────
  wakeWorkerScript = pkgs.writeShellScript "wake-worker" ''
    echo 'set my_boot_target="server"' > /var/www/boot-state/boot-state.cfg
    # Desktop NIC MAC address (enp4s0) for Scale-to-Zero Wake-on-LAN
    ${pkgs.wakeonlan}/bin/wakeonlan 10:ff:e0:40:7d:6e
    echo "Worker wake signal sent"
  '';

  resetWorkerScript = pkgs.writeShellScript "reset-worker" ''
    echo 'set my_boot_target="desktop"' > /var/www/boot-state/boot-state.cfg
    echo "Boot state reset to desktop"
  '';

  webhookConfig = pkgs.writeText "hooks.json" (builtins.toJSON [
    {
      id = "wake-worker";
      execute-command = toString wakeWorkerScript;
      command-working-directory = "/var/www/boot-state";
    }
    {
      id = "reset-worker";
      execute-command = toString resetWorkerScript;
      command-working-directory = "/var/www/boot-state";
    }
  ]);

  initBootState = pkgs.writeShellScript "init-boot-state" ''
    if [ ! -f /var/www/boot-state/boot-state.cfg ]; then
      echo 'set my_boot_target="desktop"' > /var/www/boot-state/boot-state.cfg
      chown webhook:webhook /var/www/boot-state/boot-state.cfg
    fi
  '';

  # ── Scale-to-Zero SSH Proxy & Wake Helpers ───────────────────────────
  # Used by client ProxyCommand: prints progress to stderr while waiting for
  # Desktop to boot, then transparently streams stdio via netcat.
  wakeAndProxyScript = pkgs.writeShellScriptBin "wake-and-proxy" ''
    target_host="''${1:-nixos-desktop.lab}"
    target_port="''${2:-22}"

    if ! ${pkgs.netcat}/bin/nc -z -w 1 "$target_host" "$target_port" 2>/dev/null; then
      echo "🖥️  Desktop is powered off (scale-to-zero)." >&2
      echo "⚡ Sending Wake-on-LAN and setting boot target to 'server'..." >&2
      ${wakeWorkerScript} >&2
      echo "⏳ Waiting for Desktop to boot and start SSH..." >&2

      start_time=$(date +%s)
      while ! ${pkgs.netcat}/bin/nc -z -w 1 "$target_host" "$target_port" 2>/dev/null; do
        elapsed=$(( $(date +%s) - start_time ))
        if [ "$elapsed" -ge 90 ]; then
          echo -e "\n❌ Timed out waiting for Desktop to boot after 90 seconds." >&2
          exit 1
        fi
        printf "   Booting Desktop... (%ds elapsed)\r" "$elapsed" >&2
        sleep 2
      done
      echo -e "\n✨ Desktop is online! Handing off SSH session..." >&2
    fi

    exec ${pkgs.netcat}/bin/nc "$target_host" "$target_port"
  '';

  # Interactive direct SSH bridge: `ssh sandbox@nixos-rpi4.lab`
  wakeAndBridgeScript = pkgs.writeShellScript "wake-and-bridge" ''
    target_host="nixos-desktop.lab"
    target_port="22"

    if ! ${pkgs.netcat}/bin/nc -z -w 1 "$target_host" "$target_port" 2>/dev/null; then
      echo "🖥️  Desktop is powered off (scale-to-zero)."
      echo "⚡ Sending Wake-on-LAN and setting boot target to 'server'..."
      ${wakeWorkerScript}
      echo "⏳ Waiting for Desktop to boot and start SSH..."

      start_time=$(date +%s)
      while ! ${pkgs.netcat}/bin/nc -z -w 1 "$target_host" "$target_port" 2>/dev/null; do
        elapsed=$(( $(date +%s) - start_time ))
        if [ "$elapsed" -ge 90 ]; then
          echo -e "\n❌ Timed out waiting for Desktop to boot after 90 seconds."
          exit 1
        fi
        printf "   Booting Desktop... (%ds elapsed)\r" "$elapsed"
        sleep 2
      done
      echo -e "\n✨ Desktop is online! Launching ephemeral sandbox..."
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
    ../../modules/locale.nix
    ../../modules/nix-settings.nix
    ../../modules/security.nix
    ../../modules/systemd-minimal.nix
    ../../modules/kanidm-client.nix
  ];

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
  ];
  networking.hosts."192.168.1.127" = [ "nixos-desktop" "nixos-desktop.lab" ];

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

  # ── Caddy: Tailnet reverse proxy + GRUB boot-state endpoint ───────────
  services.caddy = {
    enable = true;
    globalConfig = ''
      pki {
        ca local {
          name "Homelab Internal Root CA"
          root {
            cert /var/lib/caddy/pki/homelab-ca.crt
            key  /var/lib/caddy/pki/homelab-ca.key
          }
        }
      }
    '';
    virtualHosts = {
      # GRUB fetches boot-state.cfg over plain HTTP during early boot (no TLS stack in GRUB)
      # Security: only reachable on Tailnet (trustedInterfaces) and LAN — never public internet
      ":80" = {
        extraConfig = ''
          root * /var/www/boot-state
          file_server
        '';
      };
      # Flamenco Manager — HTTP for worker connectivity (Tailnet is already encrypted)
      "http://render.lab" = {
        extraConfig = ''
          reverse_proxy localhost:8080
        '';
      };
      "https://portfolio.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:3080
        '';
      };
      "https://git.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:3000
        '';
      };
      "https://ci.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:8000
        '';
      };
      "https://idm.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy https://localhost:8443 {
            transport http {
              tls_insecure_skip_verify
            }
          }
        '';
      };
      "https://vault.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:8222
        '';
      };
      "https://ntfy.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:2586
        '';
      };
      "https://status.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:3001
        '';
      };
      # Glance: Private Homelab Dashboard (Strictly Tailnet & LAN only, no Cloudflare tunnel)
      "https://lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:8095
        '';
      };
      "https://home.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:8095
        '';
      };
      "https://bookmarks.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:8085
        '';
      };
      "https://docs.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:28981
        '';
      };
    };
  };

  # ── Cloudflared: public tunnel for portfolio & dynamic subdomains ───────
  # Runs outbound connection to Cloudflare edge — functions 100% cleanly behind CGNAT.
  # Wildcard *.23012006.xyz routes directly to Traefik, which dynamically connects
  # to any container exposing `traefik.enable=true` and matching Host rules.
  # Cloudflared will be enabled once credentials exist at /var/lib/cloudflared/homelab-credentials.json
  # (See docs/DEPLOYMENT.md §2.5.A)
  services.cloudflared = {
    enable = true;
    tunnels."fd29c003-2ef3-45e8-bd0f-a453b25a4c31" = {
      credentialsFile = "/var/lib/cloudflared/homelab-credentials.json";
      default = "http_status:404";
      ingress = {
        "portfolio.23012006.xyz" = {
          service = "http://localhost:3080";
        };
        "portfolio.justkowal.dev" = {
          service = "http://localhost:3080";
        };
        "vault.23012006.xyz" = {
          service = "http://localhost:8222";
        };
        "ntfy.23012006.xyz" = {
          service = "http://localhost:2586";
        };
        "status.23012006.xyz" = {
          service = "http://localhost:3001";
        };
        "*.23012006.xyz" = {
          service = "http://127.0.0.1:8088";
        };
        "23012006.xyz" = {
          service = "http://127.0.0.1:8088";
        };
      };
    };
  };

  # ── Traefik: Dynamic Container Router for Cloudflare Ingress ───────────
  # Listens only on loopback (127.0.0.1:8088) behind Cloudflared tunnel.
  # Watches the Podman socket for container labels (e.g. `traefik.http.routers.app.rule=Host(...)`).
  # Security: `exposedByDefault = false` guarantees internal services are never exposed.
  services.traefik = {
    enable = true;
    group = "podman";
    staticConfigOptions = {
      entryPoints.web = {
        address = "127.0.0.1:8088";
      };
      providers.docker = {
        endpoint = "unix:///run/podman/podman.sock";
        exposedByDefault = false;
        network = "podman";
      };
      global = {
        checkNewVersion = false;
        sendAnonymousUsage = false;
      };
    };
  };

  users.users.traefik.extraGroups = [ "podman" ];

  # ── Podman & OCI Containers ────────────────────────────────────────────
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers = {
      portfolio = {
        image = "ghcr.io/justkowal/portfolio:latest";
        ports = [ "3080:3000" ];
        extraOptions = [ "--pull=always" ];
        autoStart = false;
      };

      # ── Flamenco Render Manager ──────────────────────────────────────
      flamenco-manager = {
        imageFile = flamencoManagerImage;
        image = "flamenco-manager:local";
        ports = [ "8080:8080" ];
        volumes = [
          "/var/lib/flamenco:/data"
          "/home/justkowal/Sync/Render:/data/shared-storage"
          "${flamencoManagerConfig}:/data/flamenco-manager.yaml:ro"
        ];
        autoStart = true;
      };
    };
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
        if [ -f /var/lib/woodpecker/woodpecker.sqlite ]; then
          mkdir -p "$TMP_DIR/woodpecker"
          sqlite3 /var/lib/woodpecker/woodpecker.sqlite ".backup $TMP_DIR/woodpecker/woodpecker.sqlite"
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
  };

  # ── Forgejo (Git forge + OCI container registry) ───────────────────────
  #
  # ┌─── OIDC SSO SETUP (post-deploy, one-time) ────────────────────────┐
  # │ 1. In Kanidm, create an OAuth2 Resource Server for Forgejo:       │
  # │                                                                    │
  # │    kanidm system oauth2 create forgejo "Forgejo" https://git.lab  │
  # │    kanidm system oauth2 add-redirect-url forgejo \                │
  # │      https://git.lab/user/oauth2/kanidm/callback                  │
  # │    kanidm system oauth2 show-basic-secret forgejo                 │
  # │                                                                    │
  # │ 2. In Forgejo Admin → Site Administration → Authentication:       │
  # │    Add Authentication Source → OAuth2                              │
  # │      Provider:       OpenID Connect                                │
  # │      Client ID:      forgejo                                       │
  # │      Client Secret:  <secret from step 1>                          │
  # │      Discovery URL:  https://idm.lab/oauth2/openid/forgejo/       │
  # │                      .well-known/openid-configuration             │
  # │      Scopes:         openid profile email                          │
  # │      Required Claim: (leave empty for all Kanidm users)           │
  # └───────────────────────────────────────────────────────────────────┘
  services.forgejo = {
    enable = true;
    database.type = "sqlite3";
    dump = {
      enable = true;
      backupDir = "/home/justkowal/Sync/Backups/forgejo";
      interval = "03:00";
      type = "zip";
      age = "14d";
    };
    settings = {
      DEFAULT.APP_NAME = "Homelab Forge";
      server = {
        DOMAIN = "git.lab";
        ROOT_URL = "https://git.lab/";
        HTTP_PORT = 3000;
      };
      packages.ENABLED = true;
      registry.ENABLED = true;
      # Low-memory optimisations for 4GB RPi4
      cache.ADAPTER = "memory";
      session.PROVIDER = "memory";
      indexer.REPO_INDEXER_ENABLED = false;
    };
  };

  # ── Woodpecker CI Server ───────────────────────────────────────────────
  #
  # ┌─── SECRET PROVISIONING ────────────────────────────────────────────┐
  # │ Create /etc/woodpecker/server.env (mode 0600, root:root) with:    │
  # │                                                                    │
  # │   WOODPECKER_AGENT_SECRET=<generate: openssl rand -hex 32>        │
  # │   WOODPECKER_GITEA_CLIENT=<OAuth2 Client ID from Forgejo>        │
  # │   WOODPECKER_GITEA_SECRET=<OAuth2 Client Secret from Forgejo>    │
  # │                                                                    │
  # │ To create the OAuth2 app in Forgejo:                               │
  # │   Site Admin → Applications → Create OAuth2 Application           │
  # │   Name:         Woodpecker CI                                      │
  # │   Redirect URI: https://ci.lab/authorize                           │
  # │                                                                    │
  # │ Alternative: use agenix or sops-nix to manage this file           │
  # │ declaratively. Add the appropriate flake input and use             │
  # │ age.secrets or sops.secrets to template the env file.             │
  # └───────────────────────────────────────────────────────────────────┘
  services.woodpecker-server = {
    enable = true;
    environment = {
      WOODPECKER_HOST = "https://ci.lab";
      WOODPECKER_OPEN = "false";
      WOODPECKER_ADMIN = "justkowal";
      WOODPECKER_GITEA = "true";
      WOODPECKER_GITEA_URL = "https://git.lab";
      WOODPECKER_GRPC_ADDR = "0.0.0.0:9000";
    };
    environmentFile = "/etc/woodpecker/server.env";
  };

  # ── Syncthing ──────────────────────────────────────────────────────────
  services.syncthing = {
    enable = true;
    user = "justkowal";
    dataDir = "/home/justkowal/Sync";
    configDir = "/home/justkowal/.config/syncthing";
    guiAddress = "127.0.0.1:8384";
    openDefaultPorts = true;
  };

  # ── Kanidm Server (Identity Provider) ──────────────────────────────────
  #
  # ┌─── POST-DEPLOY INITIALIZATION ────────────────────────────────────┐
  # │ 1. kanidm recover-account admin                                   │
  # │ 2. kanidm login --name admin                                      │
  # │ 3. kanidm group create linux_users                                │
  # │ 4. kanidm person create justkowal "justkowal"                     │
  # │ 5. kanidm group add-members linux_users justkowal                 │
  # │ 6. kanidm person posix set justkowal --shell /bin/bash            │
  # └───────────────────────────────────────────────────────────────────┘
  services.kanidm = {
    server.enable = true;
    server.settings = {
      origin = "https://idm.lab";
      domain = "idm.lab";
      bindaddress = "127.0.0.1:8443";
      tls_chain = "/var/lib/kanidm/cert.pem";
      tls_key = "/var/lib/kanidm/key.pem";
      db_arc_size = 536870912;  # 512MB cache limit for 4GB RPi4
    };
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

  # ── Vaultwarden: Lightweight Bitwarden Password Manager ───────────────
  services.vaultwarden = {
    enable = true;
    config = {
      ROCKET_PORT = 8222;
      ROCKET_ADDRESS = "127.0.0.1";
      DOMAIN = "https://vault.lab";
      SIGNUPS_ALLOWED = true;
    };
  };

  # ── ntfy: Unified Push Notification Dispatcher ─────────────────────────
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.lab";
      listen-http = "127.0.0.1:2586";
    };
  };

  # ── Uptime Kuma: Homelab Status & Health Dashboard ─────────────────────
  services.uptime-kuma = {
    enable = true;
    settings = {
      PORT = "3001";
      HOST = "127.0.0.1";
    };
  };

  # ── Glance: Private Homelab Dashboard (Tailnet & LAN Only) ─────────────
  services.glance = {
    enable = true;
    settings = {
      server = {
        host = "127.0.0.1";
        port = 8095;
      };
      theme = {
        background-color = "240 10 4";
        primary-color = "350 80 75";
      };
      pages = [
        {
          name = "Homelab";
          columns = [
            {
              size = "small";
              widgets = [
                {
                  type = "clock";
                  time-format = "24h";
                }
                {
                  type = "monitor";
                  title = "RPi4 Node";
                }
              ];
            }
            {
              size = "full";
              widgets = [
                {
                  type = "bookmarks";
                  groups = [
                    {
                      title = "Core Infrastructure";
                      links = [
                        { title = "Kanidm IDM"; url = "https://idm.lab"; }
                        { title = "Forgejo Git"; url = "https://git.lab"; }
                        { title = "Woodpecker CI"; url = "https://ci.lab"; }
                        { title = "Uptime Kuma Status"; url = "https://status.lab"; }
                      ];
                    }
                    {
                      title = "Workstation & Services";
                      links = [
                        { title = "Vaultwarden"; url = "https://vault.lab"; }
                        { title = "Flamenco Render Manager"; url = "http://render.lab"; }
                        { title = "ntfy Push Alerts"; url = "https://ntfy.lab"; }
                        { title = "Desktop Sunshine"; url = "https://nixos-desktop.lab:47990"; }
                        { title = "Shiori Bookmarks"; url = "https://bookmarks.lab"; }
                        { title = "Paperless Docs"; url = "https://docs.lab"; }
                      ];
                    }
                  ];
                }
              ];
            }
          ];
        }
      ];
    };
  };

  # ── Shiori: Self-Hosted Bookmarks & Web Archiver ───────────────────────
  services.shiori = {
    enable = true;
    port = 8085;
  };

  # ── Paperless-ngx: Automated Document & Receipt Archiver ───────────────
  services.paperless = {
    enable = true;
    address = "127.0.0.1";
    port = 28981;
    consumptionDir = "/home/justkowal/Sync/Documents/consume";
    consumptionDirIsPublic = true;
    settings = {
      PAPERLESS_URL = "https://docs.lab";
      PAPERLESS_OCR_LANGUAGE = "pol+eng";
      PAPERLESS_TIME_ZONE = "Europe/Warsaw";
      PAPERLESS_TASK_WORKERS = 1;
      PAPERLESS_THREADS_PER_WORKER = 1;
    };
  };

  # ── Blocky: Fast DNS Proxy, Ad-Blocker & Homelab Split-DNS ─────────────
  services.blocky = {
    enable = true;
    settings = {
      ports.dns = 53;
      upstreams.groups.default = [
        "1.1.1.1"
        "1.0.0.1"
      ];
      customDNS = {
        customTTL = "1h";
        mapping = {
          "lab" = "192.168.1.22";
          "home.lab" = "192.168.1.22";
          "bookmarks.lab" = "192.168.1.22";
          "docs.lab" = "192.168.1.22";
          "idm.lab" = "192.168.1.22";
          "git.lab" = "192.168.1.22";
          "ci.lab" = "192.168.1.22";
          "render.lab" = "192.168.1.22";
          "portfolio.lab" = "192.168.1.22";
          "nixos-rpi4.lab" = "192.168.1.22";
          "vault.lab" = "192.168.1.22";
          "ntfy.lab" = "192.168.1.22";
          "status.lab" = "192.168.1.22";
          "thinkpad-t14s-gen1-amd.lab" = "192.168.1.20";
          "nixos-desktop.lab" = "192.168.1.127";
        };
      };
      blocking = {
        denylists = {
          ads = [
            "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
          ];
        };
        clientGroupsBlock = {
          default = [ "ads" ];
        };
      };
    };
  };

  system.stateVersion = "26.05";
}

