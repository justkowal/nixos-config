{ config, pkgs, lib, ... }:

let
  cfg = config.lab.autoDeploy;
  repo = "git+https://git.lab/justkowal/nixos-configs";

  auto-deploy = pkgs.writeShellApplication {
    name = "auto-deploy";
    runtimeInputs = with pkgs; [ nix git jq coreutils gnugrep systemd ];
    text = ''
      ref=${lib.escapeShellArg "${repo}?ref=deploy/${cfg.channel}"}
      attr=${lib.escapeShellArg cfg.flakeAttr}
      min_battery=${toString cfg.minBattery}
      state=/var/lib/auto-deploy
      profile=/nix/var/nix/profiles/system

      log() { echo "[auto-deploy] $*"; }

      for ps in /sys/class/power_supply/*; do
        [ "$(cat "$ps/type" 2>/dev/null)" = Mains ] && [ "$(cat "$ps/online" 2>/dev/null)" = 1 ] && on_ac=1
      done
      if [ -z "''${on_ac:-}" ]; then
        for ps in /sys/class/power_supply/*; do
          [ "$(cat "$ps/type" 2>/dev/null)" = Battery ] || continue
          cap=$(cat "$ps/capacity" 2>/dev/null || echo 100)
          if [ "$cap" -lt "$min_battery" ]; then
            log "on battery at $cap%, skipping"
            exit 0
          fi
        done
      fi

      # caffeine.sh keeps its systemd-inhibit pid in each user's runtime dir
      for pidfile in /run/user/*/caffeine.pid; do
        [ -f "$pidfile" ] || continue
        if kill -0 "$(cat "$pidfile")" 2>/dev/null; then
          log "caffeine active ($pidfile), skipping"
          exit 0
        fi
      done

      # a booted specialisation (desktop worker) or a nixos-rebuild test must not be replaced underneath
      if [ "$(readlink -f /run/current-system)" != "$(readlink -f "$profile")" ]; then
        log "running system is not the profile default, skipping"
        exit 0
      fi

      if ! rev=$(nix flake metadata --json --refresh "$ref" | jq -er .revision); then
        log "cannot resolve $ref, skipping"
        exit 0
      fi
      if grep -qsx "$rev" "$state/bad"; then
        log "$rev already failed health here, skipping"
        exit 0
      fi
      if [ "$(cat "$state/rev" 2>/dev/null)" = "$rev" ]; then
        log "already on $rev"
        exit 0
      fi

      # max-jobs 0 and no builders: everything must come from cache.lab, never compile here
      out=$(nix build --no-link --print-out-paths --max-jobs 0 --option builders "" \
        "$ref&rev=$rev#nixosConfigurations.$attr.config.system.build.toplevel")

      if [ "$out" = "$(readlink -f /run/current-system)" ]; then
        echo "$rev" > "$state/rev"
        log "$rev builds the running system, nothing to switch"
        exit 0
      fi

      prev=$(readlink "$profile")
      log "switching to $rev ($out), previous $prev"
      nix-env -p "$profile" --set "$out"

      health_args=()
      if ! "$out/bin/switch-to-configuration" switch; then
        health_args=(--failed switch-to-configuration)
      fi

      if FLEET_COMMIT=$rev "$out/sw/bin/fleet-health" "''${health_args[@]}"; then
        echo "$rev" > "$state/rev"
        log "$rev healthy"
        exit 0
      fi

      log "health failed, rolling back to $prev"
      gen=''${prev#system-}
      gen=''${gen%-link}
      nix-env -p "$profile" --switch-generation "$gen"
      "/nix/var/nix/profiles/$prev/bin/switch-to-configuration" switch || true
      systemctl reset-failed
      echo "$rev" >> "$state/bad"
      exit 1
    '';
  };

  nixos-update-stage = pkgs.writeShellApplication {
    name = "nixos-update-stage";
    runtimeInputs = with pkgs; [ nix git nvd libnotify swaynotificationcenter coreutils gnugrep gawk jq procps ];
    text = ''
      set -euo pipefail

      FLAKE_DIR="/etc/nixos"
      STAGING_DIR="/var/tmp/nixos-pending-update"
      STATE_FILE="/var/tmp/nixos-pending-update.ready"
      DIFF_FILE="/var/tmp/nixos-pending-update.diff"
      # runs as root: write the new lock beside the staged build, never into the checkout
      LOCK_FILE="/var/tmp/nixos-pending-update.lock"

      cleanup_on_exit() {
        local exit_code=$?
        if [ -t 0 ]; then
          if [ "$exit_code" -ne 0 ]; then
            echo ""
            echo "[nixos-update-stage] Failed with exit code $exit_code."
            read -r -p "Press Enter to close..." || true
          else
            echo ""
            read -r -t 10 -p "Update staged! Press Enter to close (auto-closing in 10s)..." || true
          fi
        fi
      }
      trap cleanup_on_exit EXIT

      echo "[nixos-update-stage] Checking network connectivity..."
      if ! ping -c 1 1.1.1.1 &>/dev/null; then
        echo "[nixos-update-stage] No internet connection, skipping update stage."
        exit 1
      fi

      echo "[nixos-update-stage] Updating flake inputs in $FLAKE_DIR..."
      rm -f "$LOCK_FILE"
      nix flake update --flake "$FLAKE_DIR" --output-lock-file "$LOCK_FILE"

      echo "[nixos-update-stage] Pre-building top-level system derivation..."
      rm -rf "$STAGING_DIR"
      nix build "$FLAKE_DIR#nixosConfigurations.desktop.config.system.build.toplevel" --reference-lock-file "$LOCK_FILE" --out-link "$STAGING_DIR"

      echo "[nixos-update-stage] Generating package diff with nvd..."
      nvd diff /run/current-system "$STAGING_DIR" > "$DIFF_FILE" 2>&1 || true

      touch "$STATE_FILE"

      # Notify active desktop users via swaync-client or notify-send
      for user in $(who | awk '{print $1}' | sort -u); do
        uid=$(id -u "$user" 2>/dev/null || true)
        if [ -n "$uid" ] && [ -S "/run/user/$uid/bus" ]; then
          sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            ${pkgs.libnotify}/bin/notify-send -u normal -i system-software-update \
            "󰚰 NixOS Update Ready" \
            "New system build pre-compiled!\nClick Waybar badge or run 'nixos-update-apply' to review & switch." || true
        fi
      done

      # Signal Waybar instances to update
      pkill -RTMIN+8 waybar || true

      echo "[nixos-update-stage] Update staged successfully!"
    '';
  };

  nixos-update-apply = pkgs.writeShellApplication {
    name = "nixos-update-apply";
    runtimeInputs = with pkgs; [ nix nvd coreutils libnotify procps ];
    text = ''
      set -euo pipefail

      STAGING_DIR="/var/tmp/nixos-pending-update"
      STATE_FILE="/var/tmp/nixos-pending-update.ready"
      DIFF_FILE="/var/tmp/nixos-pending-update.diff"
      LOCK_FILE="/var/tmp/nixos-pending-update.lock"
      FLAKE_DIR="/etc/nixos"

      if [ ! -d "$STAGING_DIR" ]; then
        echo "No valid staged update found in $STAGING_DIR (stale or removed)."
        rm -f "$STATE_FILE" "$DIFF_FILE" "$STAGING_DIR"
        pkill -RTMIN+8 waybar || true
        echo "Cleaned up stale state. Click the update widget to stage a fresh update."
        echo ""
        if [ -t 0 ]; then
          read -r -p "Press Enter to close..." || true
        fi
        exit 0
      fi

      echo "=================================================="
      echo "           NixOS Pending Update Review            "
      echo "=================================================="
      echo ""

      if [ -f "$DIFF_FILE" ]; then
        cat "$DIFF_FILE"
      else
        nvd diff /run/current-system "$STAGING_DIR"
      fi

      echo ""
      echo "=================================================="
      read -r -p "Apply and switch to pre-built system now? [y/N] " response
      case "$response" in
        [yY][eE][sS]|[yY])
          echo "Switching system profile..."
          sudo nix-env -p /nix/var/nix/profiles/system --set "$STAGING_DIR"
          sudo "$STAGING_DIR/bin/switch-to-configuration" switch
          # keep the checkout in step with what is now running
          if [ -f "$LOCK_FILE" ]; then cp "$LOCK_FILE" "$FLAKE_DIR/flake.lock"; fi
          rm -f "$STATE_FILE" "$DIFF_FILE" "$STAGING_DIR" "$LOCK_FILE"
          pkill -RTMIN+8 waybar || true
          notify-send "󰄬 NixOS Update Applied" "Successfully switched to the new system build!"
          echo ""
          if [ -t 0 ]; then
            read -r -p "System switched successfully! Press Enter to close..." || true
          fi
          ;;
        *)
          echo "Switch cancelled. Update remains staged for later."
          if [ -t 0 ]; then
            read -r -t 3 -p "Closing in 3s (or press Enter)..." || true
          fi
          ;;
      esac
    '';
  };
in
{
  imports = [ ./fleet-health.nix ];

  options.lab.autoDeploy = {
    enable = lib.mkEnableOption "switching to CI-built generations from a deploy/<channel> git ref, with health check and rollback (replaces the local flake-update staging)";
    channel = lib.mkOption {
      type = lib.types.enum [ "canary" "stable" ];
      default = "canary";
      description = "Branch deploy/<channel> on git.lab to follow.";
    };
    flakeAttr = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "nixosConfigurations attribute to deploy.";
    };
    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:00:00";
      description = "systemd OnCalendar expression for deploy attempts.";
    };
    minBattery = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 30;
      description = "Skip deploys while on battery below this percentage.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (!cfg.enable) {
      environment.systemPackages = [
        nixos-update-stage
        nixos-update-apply
        pkgs.nvd
      ];

      systemd.services.nixos-update-stage = {
        description = "Pre-build and Stage Daily NixOS Flake Update";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${nixos-update-stage}/bin/nixos-update-stage";
          Nice = 19;
          IOSchedulingClass = "idle";
          IOSchedulingPriority = 7;
        };
      };

      systemd.timers.nixos-update-stage = {
        description = "Daily Timer for Staging NixOS Updates";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };
    })

    (lib.mkIf cfg.enable {
      assertions = [{
        assertion = config.lab.fleetHealth.enable;
        message = "lab.autoDeploy needs lab.fleetHealth.enable to decide on rollback.";
      }];

      lab.fleetHealth.enable = lib.mkDefault true;
      environment.systemPackages = [ auto-deploy ];

      systemd.services.auto-deploy = {
        description = "Deploy deploy/${cfg.channel} from cache.lab";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        # the switch must not restart the unit that is driving it
        restartIfChanged = false;
        stopIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${auto-deploy}/bin/auto-deploy";
          StateDirectory = "auto-deploy";
        };
      };

      systemd.timers.auto-deploy = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.schedule;
          Persistent = true;
          RandomizedDelaySec = "30min";
        };
      };
    })
  ];
}
