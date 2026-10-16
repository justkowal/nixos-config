{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.lab.focus;
  blockyApi = "http://127.0.0.1:4000/api";

  distractions = pkgs.writeText "distractions.txt" (lib.concatMapStrings (d: "${d}\n*.${d}\n") cfg.distractions);

  # on [minutes] | off | expire | sync | status
  focusSet = pkgs.writeShellApplication {
    name = "focus-set";
    runtimeInputs = with pkgs; [coreutils curl jq];
    text = ''
      state=/var/lib/focus/state.json

      write() {
        local tmp
        tmp=$(mktemp /var/lib/focus/.state.XXXXXX)
        echo "$1" > "$tmp"
        chmod 644 "$tmp"
        mv "$tmp" "$state"
      }

      publish() {
        curl -fsS -m 5 -H "Title: $1" -H "Tags: focus" -H "Priority: 2" -d "$(cat "$state")" \
          http://127.0.0.1:2586/focus >/dev/null || true
      }

      blocky() {
        curl -fsS -m 5 "${blockyApi}/blocking/$1" >/dev/null || echo "blocky api $1 failed" >&2
      }

      active() { [ "$(jq -r '.active' "$state" 2>/dev/null)" = true ]; }

      case "''${1:-status}" in
        on)
          minutes="''${2:-}"
          [[ "$minutes" =~ ^[0-9]{1,3}$ ]] && [ "$minutes" -gt 0 ] || minutes=${toString cfg.defaultMinutes}
          write "$(jq -nc --argjson u "$(( $(date +%s) + minutes * 60 ))" '{active: true, until: $u}')"
          blocky enable
          publish "Focus on"
          ;;
        off)
          write '{"active":false,"until":null}'
          blocky "disable?groups=distractions"
          publish "Focus off"
          ;;
        expire)
          if active && [ "$(jq -r '.until // 0' "$state")" -le "$(date +%s)" ]; then
            exec "$0" off
          fi
          ;;
        sync)
          # blocky starts with every group enabled, so put distractions back to match the state
          for _ in $(seq 30); do
            curl -fsS -m 2 "${blockyApi}/blocking/status" >/dev/null 2>&1 && break
            sleep 1
          done
          if active; then blocky enable; else blocky "disable?groups=distractions"; fi
          ;;
        status) cat "$state" ;;
        *) echo "usage: focus-set on [minutes] | off | expire | sync | status" >&2; exit 1 ;;
      esac
    '';
  };
  focusBin = "${focusSet}/bin/focus-set";
in {
  options.lab.focus = {
    enable = lib.mkEnableOption "fleet focus mode state, webhook hooks and blocky distractions group";

    defaultMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 25;
    };

    distractions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "youtube.com"
        "youtu.be"
        "reddit.com"
        "x.com"
        "twitter.com"
        "instagram.com"
        "facebook.com"
        "tiktok.com"
        "twitch.tv"
        "news.ycombinator.com"
        "wykop.pl"
        "9gag.com"
        "pudelek.pl"
      ];
      description = "Domains (and their subdomains) blocked while focus is on.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.blocky.settings = {
      ports.http = "127.0.0.1:4000";
      blocking.denylists.distractions = ["${distractions}"];
      blocking.clientGroupsBlock.default = ["distractions"];
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/focus 0755 webhook webhook -"
      ''f /var/lib/focus/state.json 0644 webhook webhook - {"active":false,"until":null}''
    ];

    lab.webhookHooks = [
      {
        id = "focus-on";
        execute-command = focusBin;
        pass-arguments-to-command = [
          {
            source = "string";
            name = "on";
          }
          {
            source = "url";
            name = "minutes";
          }
        ];
        include-command-output-in-response = true;
      }
      {
        id = "focus-off";
        execute-command = focusBin;
        pass-arguments-to-command = [
          {
            source = "string";
            name = "off";
          }
        ];
        include-command-output-in-response = true;
      }
      {
        id = "focus-status";
        execute-command = focusBin;
        pass-arguments-to-command = [
          {
            source = "string";
            name = "status";
          }
        ];
        include-command-output-in-response = true;
        response-headers = [
          {
            name = "Content-Type";
            value = "application/json";
          }
        ];
      }
    ];

    systemd.services.focus-expire = {
      description = "End focus mode once its time is up";
      serviceConfig = {
        Type = "oneshot";
        User = "webhook";
        Group = "webhook";
        ExecStart = "${focusBin} expire";
      };
    };

    systemd.timers.focus-expire = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "30s";
        AccuracySec = "5s";
      };
    };

    systemd.services.focus-blocky-sync = {
      description = "Apply focus state to blocky's distractions group";
      wantedBy = ["blocky.service"];
      after = ["blocky.service"];
      partOf = ["blocky.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "webhook";
        Group = "webhook";
        ExecStart = "${focusBin} sync";
      };
    };
  };
}
