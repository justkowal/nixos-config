{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.lab.previewEnvs;
  spool = "/var/spool/preview-envs";
  state = "/var/lib/preview-envs";

  previewctl = pkgs.writeShellApplication {
    name = "preview-envs";
    runtimeInputs = with pkgs; [coreutils findutils util-linux jq nixos-container config.nix.package git systemd];
    text = ''
      spool=${spool}
      state=${state}
      max=${toString cfg.maxPreviews}
      ttl=$(( ${toString cfg.ttlDays} * 86400 ))

      log() { echo "preview-envs: $*" >&2; }

      reload_caddy() { systemctl reload caddy.service || log "caddy reload failed"; }

      destroy() {
        local name=$1
        # only ever touch containers this service created
        [ -f "$state/meta/$name.json" ] || { log "$name: not a managed preview, ignoring"; return 0; }
        nixos-container destroy "$name" || log "$name: destroy failed"
        rm -f -- "$state/meta/$name.json" "$state/routes/$name.caddy"
        reload_caddy
        log "$name: destroyed"
      }

      # 10.231.a.b on the host side, 10.232.a.b in the container, a/b derived from the name
      addr_suffix() {
        local h
        h=$(printf '%s' "$1" | sha256sum | cut -c1-4)
        h=$(( 16#$h % 64516 ))
        echo "$(( h / 254 )).$(( h % 254 + 1 ))"
      }

      create() {
        local name=$1 flake=$2 sfx host guest meta
        meta="$state/meta/$name.json"
        sfx=$(addr_suffix "$name")
        host="10.231.$sfx"
        guest="10.232.$sfx"

        if [ -f "$meta" ]; then
          nixos-container update "$name" --flake "$flake"
          nixos-container start "$name" || true
        else
          if nixos-container list | grep -qxF -- "$name"; then
            log "$name: container exists but is not a managed preview, refusing"
            return 1
          fi
          if [ "$(find "$state/meta" -name '*.json' | wc -l)" -ge "$max" ]; then
            log "$name: limit of $max previews reached"
            return 1
          fi
          if grep -lqsF "\"$guest\"" "$state"/meta/*.json; then
            log "$name: address $guest collides with another preview, pick another name"
            return 1
          fi
          if ! nixos-container create "$name" --flake "$flake" --auto-start \
               --host-address "$host" --local-address "$guest"; then
            nixos-container list | grep -qxF -- "$name" && nixos-container destroy "$name"
            return 1
          fi
          nixos-container start "$name"
        fi

        jq -n --arg n "$name" --arg f "$flake" --arg ip "$guest" --argjson t "$(date +%s)" \
          '{name: $n, flake: $f, ip: $ip, updated: $t}' > "$meta.tmp"
        mv -f -- "$meta.tmp" "$meta"
        printf '@%s host %s.dev.lab\nhandle @%s {\n\treverse_proxy %s:80\n}\n' \
          "$name" "$name" "$name" "$guest" > "$state/routes/$name.caddy"
        reload_caddy
        log "$name: up at http://$name.dev.lab ($guest, $flake)"
      }

      handle() {
        local req=$1 parsed action name flake
        local flake_re='^git\+https://git\.lab/justkowal/[A-Za-z0-9][A-Za-z0-9._-]*(\?(rev=[0-9a-f]{40}|ref=[A-Za-z0-9._/-]+))?(#[A-Za-z0-9_-]+)?$'
        if [ -L "$req" ] || [ ! -f "$req" ] || [ "$(stat -c %s -- "$req")" -gt 4096 ]; then
          log "$req: not a small regular file"; return 1
        fi
        parsed=$(jq -er '
          select(type == "object" and ((keys - ["action", "name", "flake"]) | length) == 0)
          | [.action, .name, (.flake // "")]
          | select(all(type == "string"))
          | @tsv' < "$req") || { log "$req: malformed request"; return 1; }
        IFS=$'\t' read -r action name flake <<< "$parsed"

        # 11 chars is the nixos-container limit (veth interface name)
        [[ $name =~ ^[a-z][a-z0-9-]{0,10}$ ]] || { log "bad name '$name'"; return 1; }
        case $action in
          destroy) destroy "$name" ;;
          create)
            [[ $flake =~ $flake_re ]] || { log "$name: flake '$flake' rejected"; return 1; }
            create "$name" "$flake"
            ;;
          *) log "bad action '$action'"; return 1 ;;
        esac
      }

      process() {
        local f work="$state/work"
        shopt -s nullglob
        for f in "$spool"/*.json; do
          # move out of the agent-writable dir first so the file cannot be swapped under us
          mv -f -- "$f" "$work/req.json" || continue
          "$0" handle "$work/req.json" || log "request $(basename "$f") failed"
          rm -f -- "$work/req.json"
        done
      }

      reap() {
        local m name updated now
        now=$(date +%s)
        shopt -s nullglob
        for m in "$state"/meta/*.json; do
          name=$(basename "$m" .json)
          updated=$(jq -r '.updated' "$m")
          if [ $(( now - updated )) -gt "$ttl" ]; then destroy "$name"; fi
        done
      }

      mkdir -p "$state/meta" "$state/routes" "$state/work"
      case ''${1:-} in
        handle) handle "$2" ;;
        process) exec 9>"$state/lock"; flock 9; process ;;
        reap) exec 9>"$state/lock"; flock 9; reap ;;
        destroy) exec 9>"$state/lock"; flock 9; destroy "$2" ;;
        *) echo "usage: preview-envs process|reap|destroy NAME" >&2; exit 2 ;;
      esac
    '';
  };
in {
  options.lab.previewEnvs = {
    enable = lib.mkEnableOption "throwaway nixos-container preview environments fed by a CI spool";
    maxPreviews = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
    };
    ttlDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.preview-spool = {};

    # setgid keeps requests in the group, sticky stops agents deleting each other's files
    systemd.tmpfiles.rules = [
      "d ${spool} 3770 root preview-spool -"
      "d ${state} 0755 root root -"
      "d ${state}/routes 0755 root root -"
      "d ${state}/meta 0700 root root -"
      "d ${state}/work 0700 root root -"
    ];

    systemd.paths.preview-envs = {
      wantedBy = ["paths.target"];
      pathConfig.PathExistsGlob = "${spool}/*.json";
    };
    systemd.services.preview-envs = {
      description = "Create/destroy preview containers from the CI spool";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe previewctl} process";
        TimeoutStartSec = "1h";
      };
    };

    systemd.timers.preview-envs-reap = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
      };
    };
    systemd.services.preview-envs-reap = {
      description = "Destroy preview containers older than ${toString cfg.ttlDays} days";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe previewctl} reap";
      };
    };

    environment.systemPackages = [previewctl];

    # rpi4's *.dev.lab vhost forwards here with the Host header intact
    services.caddy = {
      enable = true;
      virtualHosts."http://*.dev.lab".extraConfig = ''
        import ${state}/routes/*.caddy
        handle {
          respond "No preview with this name (expired or never created)." 404
        }
      '';
    };

    # tiny local-backend agent whose only power is dropping requests into the spool.
    # "!type" makes it a required label, so normal local jobs (the nixos-configs build) never land here.
    services.woodpecker-agents.agents.preview = {
      enable = true;
      environment = {
        WOODPECKER_SERVER = "nixos-rpi4.lab:9000";
        WOODPECKER_BACKEND = "local";
        WOODPECKER_MAX_WORKFLOWS = "2";
        WOODPECKER_AGENT_LABELS = "!type=preview";
      };
      path = with pkgs; [bash coreutils jq];
      extraGroups = ["preview-spool"];
      environmentFile = [config.sops.templates."woodpecker-agent.env".path];
    };
    systemd.services.woodpecker-agent-preview.serviceConfig.ReadWritePaths = [spool];
  };
}
