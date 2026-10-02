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
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
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

  # ── Cross-Compilation ──────────────────────────────────────────────────
  # Allows native aarch64 builds (RPi4 SD images) via QEMU user-mode emulation
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # ── Bootloader: GRUB (replaces systemd-boot from shared module) ────────
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    useOSProber = false;

    # Dynamic boot routing:
    #  SHIFT held → boot desktop immediately
    #  Otherwise  → fetch boot-state.cfg from RPi4 Caddy on port 80
    #               my_boot_target=server → boot worker specialisation
    #               Pi unreachable        → boot desktop with autoshutdown_timer=1
    extraConfig = ''
      # --- Scale-to-Zero Boot Logic ---
      if keystatus --shift; then
        # Operator override: boot default desktop, skip network probe
        set timeout=3
      else
        insmod net
        insmod efinet
        insmod http

        if net_bootp; then
          if http_get http://nixos-rpi4.lab/boot-state.cfg /tmp/boot-state.cfg; then
            source /tmp/boot-state.cfg
            if [ "$my_boot_target" = "server" ]; then
              # Route to the worker specialisation
              set default="NixOS - Worker"
            fi
          else
            # Pi unreachable — boot desktop but schedule auto-shutdown
            set extra_cmdline="autoshutdown_timer=1"
          fi
        else
          # No DHCP lease — boot desktop but schedule auto-shutdown
          set extra_cmdline="autoshutdown_timer=1"
        fi
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
    device = "/dev/disk/by-label/docker";
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

  # ── Specialisation: Worker (headless GPU compute node) ─────────────────
  specialisation.worker = {
    inheritParentConfig = true;
    configuration = { config, pkgs, lib, ... }: {

      # Disable graphical UI to prevent greetd crash loops
      services.xserver.enable = false;
      services.greetd.enable = lib.mkForce false;

      # GPU Compute: expose ROCm devices to containers
      hardware.graphics.enable = lib.mkForce true;
      services.udev.extraRules = ''
        KERNEL=="kfd", GROUP="render", MODE="0666"
        SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0666"
      '';

      # Docker engine on the dedicated btrfs SSD
      virtualisation.docker = {
        enable = lib.mkForce true;
        enableOnBoot = lib.mkForce true;
        storageDriver = "btrfs";
        daemon.settings = {
          "data-root" = "/var/lib/docker";
          "default-runtime" = "runc";
        };
      };

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
        environmentFile = [ "/etc/woodpecker/agent.env" ];
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

      # ── Ephemeral SSH Sandbox ──────────────────────────────────────────
      # ForceCommand traps the login into an auto-removing Docker container
      # with GPU passthrough. The sandbox user cannot escape to a host shell.
      #
      # Security hardening:
      #  - --cap-drop ALL: no Linux capabilities inside container
      #  - --security-opt no-new-privileges: blocks suid/setuid escalation
      #  - --network bridge: isolated from host network
      #  - No --privileged: no raw host device/kernel access
      #  - No docker socket mount: cannot control the Docker daemon
      #  - All forwarding disabled: no tunneling out of the sandbox
      users.users.sandbox = {
        isNormalUser = true;
        description = "Ephemeral Docker sandbox user";
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINq047VZyk7koA7QCAW8RuGaqu8YePnLPnOIIgo0TiBS justkowal@desktop"
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

  system.stateVersion = "26.05";
}
