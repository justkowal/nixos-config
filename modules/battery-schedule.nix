{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.lab.batterySchedule;
  tlp = "${config.services.tlp.package}/bin/tlp";
  bat = cfg.battery;

  typelibPath = lib.makeSearchPath "lib/girepository-1.0" (with pkgs; [
    evolution-data-server
    libical
    glib.out
    gobject-introspection
    libsoup_3
    json-glib
  ]);

  calendarCheck = pkgs.writeShellApplication {
    name = "battery-schedule-calendar";
    runtimeInputs = [(pkgs.python3.withPackages (ps: [ps.pygobject3])) pkgs.systemd];
    text = ''
      export GI_TYPELIB_PATH="${typelibPath}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      mode=$(python3 ${./battery-schedule-calendar.py} ${lib.escapeShellArgs cfg.keywords})
      if [ "$mode" = travel ]; then
        systemctl start battery-charge@travel.service
      else
        systemctl start battery-charge@default.service
      fi
    '';
  };

  setCharge = pkgs.writeShellScript "battery-charge" ''
    set -eu
    case "$1" in
      # thresholds from the TLP config, so TLP stays the only owner of the defaults
      default) ${tlp} setcharge ;;
      travel) ${tlp} setcharge 0 100 ${bat} ;;
      *) echo "unknown mode $1" >&2; exit 1 ;;
    esac
    echo "$1" > /run/battery-schedule/mode
  '';

  wearLog = pkgs.writeShellScript "battery-wear-log" ''
    set -eu
    dir=/var/lib/node-exporter-textfile
    b=/sys/class/power_supply/${bat}
    ${pkgs.coreutils}/bin/install -d -m 0755 "$dir"
    if [ -r "$b/energy_full" ]; then
      full=$(cat "$b/energy_full"); design=$(cat "$b/energy_full_design"); unit=wh
    else
      full=$(cat "$b/charge_full"); design=$(cat "$b/charge_full_design"); unit=ah
    fi
    cycles=$(cat "$b/cycle_count" 2>/dev/null || echo 0)
    tmp=$(${pkgs.coreutils}/bin/mktemp "$dir/.battery.XXXXXX")
    ${pkgs.gawk}/bin/awk -v f="$full" -v d="$design" -v c="$cycles" -v u="$unit" -v b="${bat}" 'BEGIN {
      printf "# TYPE battery_full_%s gauge\nbattery_full_%s{battery=\"%s\"} %.3f\n", u, u, b, f / 1e6
      printf "# TYPE battery_full_design_%s gauge\nbattery_full_design_%s{battery=\"%s\"} %.3f\n", u, u, b, d / 1e6
      printf "# TYPE battery_health_ratio gauge\nbattery_health_ratio{battery=\"%s\"} %.4f\n", b, f / d
      printf "# TYPE battery_cycle_count gauge\nbattery_cycle_count{battery=\"%s\"} %d\n", b, c
    }' > "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$dir/battery.prom"
  '';
in {
  options.lab.batterySchedule = {
    enable = lib.mkEnableOption "calendar-aware charge thresholds (full charge before travel days) and daily battery wear log";

    user = lib.mkOption {
      type = lib.types.str;
      default = "justkowal";
      description = "User whose evolution-data-server calendars are checked and who may switch charge modes.";
    };

    keywords = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["travel"];
      example = ["travel" "wyjazd" "delegacja"];
      description = "Case-insensitive substrings matched against tomorrow's event titles, categories and locations.";
    };

    checkAt = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 21:00";
      description = "systemd OnCalendar for the evening calendar check.";
    };

    battery = lib.mkOption {
      type = lib.types.str;
      default = "BAT0";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.tlp.enable;
        message = "lab.batterySchedule needs services.tlp, which owns the charge thresholds.";
      }
    ];

    systemd.services."battery-charge@" = {
      description = "Set battery charge thresholds (%i)";
      after = ["tlp.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${setCharge} %i";
        RuntimeDirectory = "battery-schedule";
        RuntimeDirectoryPreserve = true;
      };
    };

    # the only root action the user side can trigger: these two exact units
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "${cfg.user}" &&
            action.lookup("verb") == "start" &&
            (action.lookup("unit") == "battery-charge@travel.service" ||
             action.lookup("unit") == "battery-charge@default.service")) {
          return polkit.Result.YES;
        }
      });
    '';

    systemd.user.services.battery-calendar = {
      description = "Raise the charge limit if tomorrow is a travel day";
      unitConfig.ConditionUser = cfg.user;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${calendarCheck}/bin/battery-schedule-calendar";
      };
    };

    systemd.user.timers.battery-calendar = {
      wantedBy = ["timers.target"];
      unitConfig.ConditionUser = cfg.user;
      timerConfig = {
        OnCalendar = cfg.checkAt;
        Persistent = true;
      };
    };

    systemd.services.battery-wear-log = {
      description = "Write battery capacity and design capacity for the node-exporter textfile collector";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = wearLog;
      };
    };

    systemd.timers.battery-wear-log = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        OnBootSec = "5min";
        Persistent = true;
      };
    };
  };
}
