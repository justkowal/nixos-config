{config, lib, pkgs, ...}: let
  cfg = config.lab.streamHost;
  user = "justkowal";
  marker = "/run/stream-host/active";
  systemctl = "${config.systemd.package}/bin/systemctl";

  # prep/undo wrappers: the marker is what idle watchdogs read, since Sunshine has no "is streaming" query
  streamMark = pkgs.writeShellScript "stream-mark" ''
    case "$1" in
      on) : > ${marker} ;;
      off) rm -f ${marker} ;;
    esac
  '';

  streamActive = pkgs.writeShellScriptBin "stream-host-active" ''
    [ -e ${marker} ]
  '';

  sessions = {
    stream-gamescope = "gamescope -e -f -- steam -gamepadui";
    stream-hyprland = "Hyprland";
  };

  sessionUnit = name: cmd: {
    description = "Moonlight stream session (${cmd})";
    after = ["systemd-user-sessions.service" "systemd-logind.service"];
    wants = ["dbus.socket" "systemd-logind.service"];
    conflicts = map (n: "${n}.service") (lib.remove name (lib.attrNames sessions));
    restartIfChanged = false;
    environment = {
      XDG_SESSION_TYPE = "wayland";
      XDG_SESSION_CLASS = "user";
    };
    script = ''
      export PATH=/run/wrappers/bin:/etc/profiles/per-user/${user}/bin:/run/current-system/sw/bin:$PATH
      exec ${cmd}
    '';
    serviceConfig = {
      User = user;
      PAMName = "stream-session";
      TTYPath = "/dev/tty7";
      TTYReset = "yes";
      TTYVHangup = "yes";
      TTYVTDisallocate = "yes";
      StandardInput = "tty-fail";
      StandardOutput = "journal";
      StandardError = "journal";
      UtmpIdentifier = "tty7";
      UtmpMode = "user";
    };
  };

  # start the compositor before Sunshine probes outputs; give it a moment to modeset
  sessionApp = name: unit: {
    inherit name;
    prep-cmd = [
      {
        do = toString (pkgs.writeShellScript "${unit}-start" "${systemctl} start ${unit}.service && sleep 4");
        undo = "${systemctl} stop ${unit}.service";
      }
    ];
    auto-detach = "true";
  };

  forceOutput = pkgs.writeShellScript "stream-force-output" ''
    set -eu
    conn=${lib.escapeShellArg (toString cfg.edidConnector)}
    for d in /sys/kernel/debug/dri/*/"$conn"; do
      [ -e "$d/edid_override" ] || continue
      cat ${pkgs.edid-generator}/lib/firmware/edid/${cfg.edidResolution}.bin > "$d/edid_override"
    done
    for s in /sys/class/drm/card*-"$conn"/status; do
      echo on > "$s"
    done
  '';
in {
  options.lab.streamHost = {
    enable = lib.mkEnableOption "Moonlight streaming from the headless worker specialisation";
    edidConnector = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "HDMI-A-1";
      description = "Connector to fake a monitor on in worker mode (EDID override + forced status). null means an HDMI dummy plug provides the output.";
    };
    edidResolution = lib.mkOption {
      type = lib.types.enum ["1280x720" "1920x1080" "2560x1440" "3840x2160"];
      default = "1920x1080";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [streamActive];
    systemd.tmpfiles.rules = ["d /run/stream-host 0755 ${user} users - -"];

    services.sunshine.settings.global_prep_cmd = builtins.toJSON [
      {
        do = "${streamMark} on";
        undo = "${streamMark} off";
      }
    ];

    # desktop mode: the user is already in Hyprland
    services.sunshine.applications.apps = [
      {name = "Desktop";}
      {
        name = "Steam Big Picture";
        detached = ["setsid steam steam://open/bigpicture"];
        prep-cmd = [
          {
            do = "";
            undo = "setsid steam steam://close/bigpicture";
          }
        ];
      }
    ];

    specialisation.worker.configuration = {
      # no greeter here, so run the user manager (Sunshine, PipeWire) from boot
      users.users.${user}.linger = true;
      systemd.user.services.sunshine = {
        wantedBy = lib.mkForce ["default.target"];
        partOf = lib.mkForce [];
        wants = lib.mkForce [];
        after = lib.mkForce [];
      };

      services.sunshine.applications.apps = lib.mkForce [
        (sessionApp "Steam (gamescope)" "stream-gamescope")
        (sessionApp "Hyprland" "stream-hyprland")
      ];

      systemd.services =
        lib.mapAttrs sessionUnit sessions
        // lib.optionalAttrs (cfg.edidConnector != null) {
          stream-force-output = {
            description = "Fake a monitor on ${cfg.edidConnector} for headless capture";
            wantedBy = ["multi-user.target"];
            # runtime debugfs/sysfs instead of drm.edid_firmware: the worker is entered by switch-to-configuration, so kernel params never apply
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = toString forceOutput;
            };
          };
        };

      security.pam.services.stream-session.startSession = true;

      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              subject.user == "${user}" &&
              ${builtins.toJSON (map (n: "${n}.service") (lib.attrNames sessions))}.indexOf(action.lookup("unit")) >= 0) {
            return polkit.Result.YES;
          }
        });
      '';
    };
  };
}
