{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  # ── Flamenco Worker — not in nixpkgs ───────────────────────────────────
  # ponytail: first build will fail with hash mismatch — copy the correct hash from the error
  flamenco-worker = pkgs.stdenv.mkDerivation {
    pname = "flamenco-worker";
    version = "3.6";
    src = pkgs.fetchzip {
      url = "https://flamenco.blender.org/downloads/flamenco-3.6-linux-amd64.tar.gz";
      hash = "sha256-aZ5hqxssAyeOj/SMGqU0p8aL02I2tidndFAcvjpgMCk=";
    };
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p $out/bin
      install -m755 flamenco-worker $out/bin/
    '';
  };

  flamencoWorkerConfig = pkgs.writeText "flamenco-worker.yaml" ''
    _meta:
      version: 3
    manager_url: http://render.lab
    shared_storage_path: /home/justkowal/Sync/Render
  '';

  sandboxScript = pkgs.writeShellScript "sandbox-entry" ''
    exec ${pkgs.docker}/bin/docker run --rm -it \
      --device /dev/kfd --device /dev/dri \
      --security-opt no-new-privileges:true \
      --cap-drop ALL \
      --network bridge \
      ubuntu:latest /bin/bash
  '';
in {
  imports = [
    ./hardware-configuration.nix
    ../../modules/overlays.nix
    ../../modules/boot.nix
    ../../modules/locale.nix
    ../../modules/user.nix
    ../../modules/nix-settings.nix
    ../../modules/services.nix
    ../../modules/kernel.nix
    ../../modules/desktop.nix
    ../../modules/shell.nix
    ../../modules/apps.nix
    ../../modules/systemd-minimal.nix
    ../../modules/performance.nix
    ../../modules/hardware.nix
    ../../modules/networking.nix
    ../../modules/vpn.nix
    ../../modules/ai.nix
    ../../modules/audio-production.nix
    ../../modules/security.nix
    ../../modules/kanidm-client.nix
    ../../modules/auto-update.nix
  ];

  home-manager.backupFileExtension = "backup";

  networking.hostName = "nixos-desktop";
  networking.networkmanager.enable = true;
  networking.interfaces.enp4s0.wakeOnLan.enable = true;

  # ── Cross-Compilation ──────────────────────────────────────────────────
  # Allows native aarch64 builds (RPi4 SD images) via QEMU user-mode emulation
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # ── Distributed Builds (Laptop Assist) ─────────────────────────────────
  # Allows the Laptop (ThinkPad T14s) to assist with parallel x86_64 compilation
  # when available over Tailscale/LAN. Capped at 2 jobs and x86_64 only so it
  # never starves the Desktop or takes slow QEMU ARM64 emulation tasks.
  networking.hosts."100.69.154.81" = [ "thinkpad-t14s-gen1-amd" "thinkpad-t14s-gen1-amd.lab" ];
  networking.hosts."100.113.193.14" = [
    "nixos-rpi4"
    "nixos-rpi4.lab"
    "lab"
    "home.lab"
    "status.lab"
    "idm.lab"
    "git.lab"
    "ci.lab"
    "vault.lab"
    "bookmarks.lab"
    "render.lab"
    "portfolio.lab"
  ];

  nix.buildMachines = [
    {
      hostName = "thinkpad-t14s-gen1-amd.lab";
      systems = [ "x86_64-linux" ];
      sshUser = "justkowal";
      sshKey = "/home/justkowal/.ssh/id_ed25519";
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSVAxQzFtTDVzRzFwVXBHVjJjR2daWHRKWHNLTm1ndmxBM1JvbU16NDFiSi8=";
      maxJobs = 2;
      speedFactor = 1;
      supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    }
  ];

  # ── Bootloader: systemd-boot (UEFI / bcachefs compatible) ───────────────
  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 10;
  };
  boot.loader.timeout = 3;

  # ── Dynamic Boot Target Router (Scale-to-Zero) ─────────────────────────
  # On boot, queries the RPi4 orchestrator. If the orchestrator requested
  # worker mode, immediately transitions to the headless worker specialisation.
  systemd.services.boot-target-router = {
    description = "Scale-to-zero boot target router";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      STATE_FILE="/tmp/boot-state.cfg"
      if ${pkgs.curl}/bin/curl -s --connect-timeout 2 http://nixos-rpi4.lab/boot-state.cfg -o "$STATE_FILE"; then
        if grep -q 'my_boot_target="server"' "$STATE_FILE"; then
          echo "Orchestrator requested worker specialisation. Switching..."
          /run/current-system/specialisation/worker/bin/switch-to-configuration switch
        else
          echo "Orchestrator requested desktop mode. Staying in default session."
        fi
      else
        echo "Orchestrator unreachable on boot."
      fi
    '';
  };

  # ── Network-Online: re-enable for WoL DHCP lease ordering ─────────────
  # Overrides the mkDefault false in modules/systemd-minimal.nix so that
  # CI agents and workers don't race ahead of DHCP.
  systemd.services.NetworkManager-wait-online.enable = lib.mkForce true;
  systemd.targets.network-online.wantedBy = [ "multi-user.target" ];

  # ── Dedicated Docker Scratch Disk (120GB SATA SSD) ─────────────────────
  fileSystems."/var/lib/docker" = {
    device = "/dev/disk/by-id/ata-ADATA_SP900_7F1520009632-part1";
    fsType = "btrfs";
    options = [ "noatime" "compress=zstd" "discard=async" "nofail" ];
  };

  # ── Autoshutdown Watchdog ──────────────────────────────────────────────
  # If the kernel was booted with autoshutdown_timer=1 (Pi was unreachable),
  # wait 5 minutes then power off if no real user sessions exist.
  systemd.services.autoshutdown-watchdog = {
    description = "Auto-shutdown when booted without orchestrator";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
    script = ''
      if ! grep -q "autoshutdown_timer=1" /proc/cmdline; then
        exit 0
      fi
      echo "autoshutdown_timer=1 detected, sleeping 5 minutes..."
      sleep 300
      # Ignore greeter/gdm/sddm sessions — only count real users
      active_sessions=$(${pkgs.systemd}/bin/loginctl list-sessions --no-legend | \
        ${pkgs.gawk}/bin/awk '{print $3}' | \
        grep -v -E '^(greeter|gdm|sddm|lightdm)$' | \
        wc -l)
      if [ "$active_sessions" -eq 0 ]; then
        echo "No active user sessions. Powering off."
        ${pkgs.systemd}/bin/systemctl poweroff
      else
        echo "Active sessions found ($active_sessions). Staying alive."
      fi
    '';
  };

  # ── Worker Slice (desktop mode throttle) ───────────────────────────────
  # Background worker daemons run in this cgroup slice so they don't starve
  # the Wayland compositor during interactive desktop use.
  systemd.slices."worker" = {
    description = "Throttled slice for background worker daemons";
    sliceConfig = {
      CPUQuota = "1000%";
      MemoryMax = "20G";
      Nice = 19;
    };
  };

  # ── Weekly filesystem integrity check ──────────────────────────────────
  systemd.services.bcachefs-scrub = {
    description = "Weekly Bcachefs Scrub";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bcachefs-tools}/bin/bcachefs fsck /dev/disk/by-uuid/91169176-2eea-4719-8327-2e0bbc3cc0c1";
    };
  };
  systemd.timers.bcachefs-scrub = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };

  # ── Real-time PAM limits for low-latency audio (PipeWire) ──────────────
  security.pam.loginLimits = [
    {
      domain = "@audio";
      item = "rtprio";
      type = "-";
      value = "99";
    }
    {
      domain = "@audio";
      item = "memlock";
      type = "-";
      value = "unlimited";
    }
    {
      domain = "@audio";
      item = "nice";
      type = "-";
      value = "-19";
    }
  ];

  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    vim
    pciutils
    usbutils
    sops
    ssh-to-age
  ];

  powerManagement.cpuFreqGovernor = "performance";

  # ── Dedicated Docker Engine (btrfs SSD partition) ──────────────────────
  virtualisation.docker = {
    enable = lib.mkForce true;
    enableOnBoot = lib.mkForce true;
    storageDriver = "btrfs";
    daemon.settings = {
      "data-root" = "/var/lib/docker";
      "default-runtime" = "runc";
    };
  };

  # ── GPU Compute: expose ROCm devices to containers ─────────────────────
  services.udev.extraRules = ''
    KERNEL=="kfd", GROUP="render", MODE="0666"
    SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0666"
  '';

  # ── Ephemeral SSH Sandbox (available in both desktop & worker modes) ───
  users.users.sandbox = {
    isNormalUser = true;
    description = "Ephemeral Docker sandbox user";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINq047VZyk7koA7QCAW8RuGaqu8YePnLPnOIIgo0TiBS justkowal@desktop"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG1S6Xyulmhl+KjN9oM/jsXsQlDi1I6gd9KFmkvnYV+9 justkowal@thinkpad"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFcpRlVj1XgB7fm5tuY5GJqTLpsAlYeZCgkIH3cZofFl sandbox@nixos-rpi4"
    ];
    extraGroups = [ "docker" ];
  };

  services.openssh.extraConfig = ''
    Match User sandbox
      ForceCommand ${sandboxScript}
      AllowTcpForwarding no
      AllowStreamLocalForwarding no
      AllowAgentForwarding no
      X11Forwarding no
      PermitTunnel no
  '';

  # ── Specialisation: Worker (headless GPU compute node) ─────────────────
  specialisation.worker = {
    inheritParentConfig = true;
    configuration = { config, pkgs, lib, ... }: {

      # Disable graphical UI to prevent greetd crash loops
      services.xserver.enable = false;
      services.greetd.enable = lib.mkForce false;

      # Woodpecker CI agent → RPi4 orchestrator
      services.woodpecker-agents.agents.docker = {
        enable = true;
        environment = {
          WOODPECKER_SERVER = "nixos-rpi4.lab:9000";
          WOODPECKER_BACKEND = "docker";
          DOCKER_HOST = "unix:///var/run/docker.sock";
          WOODPECKER_MAX_WORKFLOWS = "4";
        };
        extraGroups = [ "docker" ];
        environmentFile = [ config.sops.templates."woodpecker-agent.env".path ];
      };

      # ── Blender + Flamenco Render Worker ─────────────────────────────
      environment.systemPackages = [ pkgs.blender ];

      systemd.services.flamenco-worker = {
        description = "Flamenco Render Worker — connects to render.lab";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "simple";
          User = "justkowal";
          Group = "users";
          Restart = "on-failure";
          RestartSec = 30;
          WorkingDirectory = "/var/lib/flamenco-worker";
          StateDirectory = "flamenco-worker";
          ExecStart = "${flamenco-worker}/bin/flamenco-worker --config ${flamencoWorkerConfig}";
        };
        # Blender must be in PATH for the worker to execute renders
        path = [ pkgs.blender ];
      };

      # Ensure Syncthing render directory matches the Manager's shared storage path
      systemd.tmpfiles.rules = [
        "d /home/justkowal/Sync/Render 0755 justkowal users -"
      ];

      # ── Unified Worker Watchdog ────────────────────────────────────────
      # Monitors ALL worker workloads every 30 seconds:
      #   1. Running Woodpecker CI Docker containers
      #   2. Active sandbox SSH sessions
      #   3. Active Blender render processes (spawned by flamenco-worker)
      # If all report 0 activity for 20 consecutive checks (10 minutes),
      # the machine powers off to complete the scale-to-zero cycle.
      systemd.services.worker-watchdog = {
        description = "Unified worker idle watchdog — poweroff after 10min inactivity";
        wantedBy = [ "multi-user.target" ];
        after = [ "docker.service" ];
        serviceConfig = {
          Type = "simple";
          Restart = "always";
          RestartSec = 30;
        };
        path = with pkgs; [ docker systemd procps gnugrep coreutils ];
        script = ''
          IDLE_COUNT=0
          IDLE_THRESHOLD=20  # 20 × 30s = 10 minutes
          while true; do
            containers=$(docker ps -q 2>/dev/null | wc -l)
            ssh_sessions=$(who 2>/dev/null | grep -c "sandbox" || true)
            renders=$(pgrep -c "blender" 2>/dev/null || true)

            if [ "$containers" -eq 0 ] && [ "$ssh_sessions" -eq 0 ] && [ "$renders" -eq 0 ]; then
              IDLE_COUNT=$((IDLE_COUNT + 1))
              echo "Idle $IDLE_COUNT/$IDLE_THRESHOLD (containers=$containers ssh=$ssh_sessions renders=$renders)"
            else
              IDLE_COUNT=0
              echo "Activity detected (containers=$containers ssh=$ssh_sessions renders=$renders)"
            fi

            if [ "$IDLE_COUNT" -ge "$IDLE_THRESHOLD" ]; then
              echo "Idle threshold reached. Powering off."
              systemctl poweroff
            fi

            sleep 30
          done
        '';
      };
    };
  };

  # ── SOPS Secrets & Automated Tailnet Auto-Join ────────────────────────
  sops = {
    defaultSopsFile = ../rpi4/secrets/secrets.yaml;
    defaultSopsFormat = "yaml";
    age.sshKeyPaths = [
      "/home/justkowal/.ssh/id_ed25519"
    ];
    age.keyFile = "/home/justkowal/.config/sops/age/keys.txt";
    validateSopsFiles = false;
    secrets."tailscale_auth_key" = {};
    secrets."woodpecker_agent_secret" = {};
    templates."woodpecker-agent.env".content = ''
      WOODPECKER_AGENT_SECRET=''${config.sops.placeholder.woodpecker_agent_secret}
    '';
  };

  # Ensure Syncthing, Render, Notes, GameSaves, and Documents directories exist with correct user ownership
  systemd.tmpfiles.rules = [
    "d /home/justkowal/Sync 0755 justkowal users -"
    "d /home/justkowal/Sync/Render 0755 justkowal users -"
    "d /home/justkowal/Sync/Notes 0755 justkowal users -"
    "d /home/justkowal/Sync/GameSaves 0755 justkowal users -"
    "d /home/justkowal/Sync/Documents 0755 justkowal users -"
    "d /home/justkowal/Sync/Documents/consume 0755 justkowal users -"
  ];

  # ── Sunshine: Low-latency Game & Desktop Streaming Host for Moonlight ──
  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = true;
    openFirewall = true;
  };

  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets."tailscale_auth_key".path;
    extraUpFlags = [ "--accept-routes" "--operator=justkowal" ];
  };

  # ── Unified Homelab Alert Listener (ntfy → SwayNC) ─────────────────────
  systemd.user.services.ntfy-listener = {
    description = "Homelab ntfy alert listener (SwayNC desktop notifications)";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = 10;
    };
    path = with pkgs; [ curl jq libnotify ];
    script = ''
      while true; do
        curl -s --connect-timeout 5 -m 3600 "https://ntfy.lab/alerts/json" 2>/dev/null | while read -r line; do
          event=$(echo "$line" | jq -r '.event // empty' 2>/dev/null)
          if [ "$event" = "message" ]; then
            title=$(echo "$line" | jq -r '.title // "Homelab Alert"' 2>/dev/null)
            message=$(echo "$line" | jq -r '.message // ""' 2>/dev/null)
            priority=$(echo "$line" | jq -r '.priority // 3' 2>/dev/null)
            urgency="normal"
            if [ "$priority" -ge 4 ]; then
              urgency="critical"
            elif [ "$priority" -le 2 ]; then
              urgency="low"
            fi
            notify-send -u "$urgency" -a "Homelab" "$title" "$message"
          fi
        done
        sleep 5
      done
    '';
  };

  system.stateVersion = "26.05";
}


