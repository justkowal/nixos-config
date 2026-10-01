{ config, pkgs, lib, ... }:

let
  nixos-update-stage = pkgs.writeShellApplication {
    name = "nixos-update-stage";
    runtimeInputs = with pkgs; [ nix git nvd libnotify swaynotificationcenter coreutils gnugrep gawk jq procps ];
    text = ''
      set -euo pipefail

      FLAKE_DIR="/etc/nixos"
      STAGING_DIR="/var/tmp/nixos-pending-update"
      STATE_FILE="/var/tmp/nixos-pending-update.ready"
      DIFF_FILE="/var/tmp/nixos-pending-update.diff"

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
      nix flake update --flake "$FLAKE_DIR"

      echo "[nixos-update-stage] Pre-building top-level system derivation..."
      rm -rf "$STAGING_DIR"
      nix build "$FLAKE_DIR#nixosConfigurations.desktop.config.system.build.toplevel" --out-link "$STAGING_DIR"

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
          rm -f "$STATE_FILE" "$DIFF_FILE" "$STAGING_DIR"
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
  environment.systemPackages = [
    nixos-update-stage
    nixos-update-apply
    pkgs.nvd
  ];

  # Daily systemd timer & service for background staging
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
}
