{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.lab.led;
  focus = config.lab.focus.openrgb;

  src = pkgs.runCommand "lab-led-src" {} ''
    mkdir -p $out
    cp ${../scripts/lab-led.py} $out/lab-led.py
    cp ${../scripts/guis/lab_bus.py} $out/lab_bus.py
  '';
  python = pkgs.python3.withPackages (ps: [ps.openrgb-python]);
in {
  options.lab.led = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = focus.enable;
      description = "LED layer: load OpenRGB profiles (saved on the OpenRGB server) when bus events arrive.";
    };
    profiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        "focus.on" = focus.focusProfile;
        "focus.off" = focus.defaultProfile;
      };
      example = {"scene.done:leave" = "default";};
      description = "Event name (or name:payload-name) to OpenRGB profile.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.lab-led = {
      Unit = {
        Description = "Kowal Lab LED layer";
        PartOf = ["graphical-session.target"];
        After = ["graphical-session.target" "labd.service"];
      };
      Service = {
        ExecStart = "${python}/bin/python3 ${src}/lab-led.py ${pkgs.writeText "lab-led.json" (builtins.toJSON cfg.profiles)}";
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install.WantedBy = ["graphical-session.target"];
    };
  };
}
