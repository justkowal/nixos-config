{ config, lib, pkgs, ... }:

let
  cfg = config.lab.fleetHealth;
  host = config.networking.hostName;
  rpi4 = "nixos-rpi4";

  dmUnit =
    if config.services.greetd.enable then "greetd.service"
    else if config.services.xserver.enable then "display-manager.service"
    else null;

  checkLines = lib.concatStringsSep "\n" (
    [ ''check failed-units test -z "$(systemctl list-units --state=failed --no-legend --plain | tee /dev/stderr)"'' ]
    ++ lib.optional (host != rpi4)
      # --until-direct=false: a DERP-relayed pong still proves the tailnet path works
      "check tailscale-rpi4 tailscale ping --until-direct=false -c 3 --timeout 5s ${rpi4}"
    ++ lib.optional (dmUnit != null) "check display-manager systemctl is-active --quiet ${dmUnit}"
    ++ lib.imap1 (i: cmd: "check extra${toString i} bash -c ${lib.escapeShellArg cmd}") cfg.extraChecks
  );

  fleet-health = pkgs.writeShellApplication {
    name = "fleet-health";
    runtimeInputs = with pkgs; [ coreutils curl systemd config.services.tailscale.package bash ];
    text = ''
      host=${lib.escapeShellArg host}
      commit="''${FLEET_COMMIT:-${if config.system.configurationRevision != null then config.system.configurationRevision else "unknown"}}"
      textfile_dir=/var/lib/node-exporter-textfile
      failed=()

      check() {
        local name=$1
        shift
        if ! timeout 120 "$@"; then
          echo "[fleet-health] check failed: $name"
          failed+=("$name")
        fi
      }

      if [ "''${1:-}" = "--failed" ]; then
        failed=("$2")
      else
        # let units started by the switch settle before judging them
        timeout 300 systemctl is-system-running --wait >/dev/null || true
        ${checkLines}
      fi

      if [ ''${#failed[@]} -eq 0 ]; then status=ok; first=none; else status=fail; first=''${failed[0]}; fi
      msg="host=$host commit=$commit status=$status check=$first"
      echo "[fleet-health] $msg"

      curl -fsS -m 10 -o /dev/null \
        -H "Title: fleet-health $host $status" \
        -H "Tags: $status" \
        -H "Priority: $([ "$status" = ok ] && echo default || echo high)" \
        -d "$msg" https://ntfy.lab/fleet-health \
        || echo "[fleet-health] ntfy post failed"

      [ -d "$textfile_dir" ] || install -d -m 0755 "$textfile_dir"
      tmp=$(mktemp "$textfile_dir/.fleet_health.XXXXXX")
      {
        echo "# HELP fleet_health_ok 1 if the last fleet-health run passed."
        echo "# TYPE fleet_health_ok gauge"
        echo "fleet_health_ok{host=\"$host\",commit=\"$commit\"} $([ "$status" = ok ] && echo 1 || echo 0)"
        echo "# TYPE fleet_health_last_run_timestamp_seconds gauge"
        echo "fleet_health_last_run_timestamp_seconds{host=\"$host\"} $(date +%s)"
        echo "# TYPE fleet_health_check_failed gauge"
        for c in "''${failed[@]}"; do
          echo "fleet_health_check_failed{host=\"$host\",check=\"$c\"} 1"
        done
      } > "$tmp"
      chmod 0644 "$tmp"
      mv "$tmp" "$textfile_dir/fleet_health.prom"

      [ "$status" = ok ]
    '';
  };
in
{
  options.lab.fleetHealth = {
    enable = lib.mkEnableOption "post-switch fleet health checks reported to ntfy and node-exporter";
    extraChecks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "systemctl is-active --quiet docker.service" ];
      description = "Host-specific shell commands; any non-zero exit fails the health check.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ fleet-health ];

    systemd.services.fleet-health = {
      description = "Fleet health check";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${fleet-health}/bin/fleet-health";
      };
    };
  };
}
