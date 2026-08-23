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

      echo "[nixos-update-stage] Checking network connectivity..."
      if ! ping -c 1 1.1.1.1 &>/dev/null; then
        echo "[nixos-update-stage] No internet connection, skipping update stage."
        exit 0
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
        echo "No staged update found in $STAGING_DIR."
        echo "Run 'sudo nixos-update-stage' to check and stage updates."
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
          sudo "$STAGING_DIR/bin/switch" switch
          rm -f "$STATE_FILE" "$DIFF_FILE"
          pkill -RTMIN+8 waybar || true
          notify-send "󰄬 NixOS Update Applied" "Successfully switched to the new system build!"
          ;;
        *)
          echo "Switch cancelled. Update remains staged for later."
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
