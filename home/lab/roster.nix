{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.lab.roster;

  src = pkgs.runCommand "lab-roster-src" {} ''
    mkdir -p $out
    cp ${../scripts/lab-roster.py} $out/lab-roster.py
    cp ${../scripts/guis/lab_bus.py} $out/lab_bus.py
  '';
in {
  options.lab.roster = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Publish which of your devices are reachable (roster.changed, roster.device) from tailscale status.";
    };
    devices = lib.mkOption {
      default = {};
      description = "Friendly names, keyed by the tailscale dns label (the part before the first dot).";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          title = lib.mkOption {type = lib.types.str;};
          kind = lib.mkOption {
            type = lib.types.str;
            default = "device";
          };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    lab.roster.devices = {
      thinkpad-t14s-gen1-amd = {
        title = lib.mkDefault "Laptop";
        kind = lib.mkDefault "laptop";
      };
      nixos-desktop = {
        title = lib.mkDefault "Desktop";
        kind = lib.mkDefault "desktop";
      };
      nixos-rpi4 = {
        title = lib.mkDefault "Hub";
        kind = lib.mkDefault "hub";
      };
      nothing-phone-2a = {
        title = lib.mkDefault "Phone";
        kind = lib.mkDefault "phone";
      };
    };

    lab.keymap.entries = [
      {
        mods = "$mod ALT";
        key = "D";
        exec = "lab publish roster.show --source keymap";
        group = "Devices";
        label = "Show devices";
      }
    ];

    systemd.user.services.lab-roster = {
      Unit = {
        Description = "Kowal Lab device roster";
        PartOf = ["graphical-session.target" "labd.service"];
        After = ["graphical-session.target" "labd.service"];
      };
      Service = {
        ExecStart = "${pkgs.python3}/bin/python3 ${src}/lab-roster.py ${pkgs.writeText "lab-roster.json" (builtins.toJSON cfg.devices)}";
        Environment = ["TAILSCALE=/run/current-system/sw/bin/tailscale"];
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = ["graphical-session.target"];
    };
  };
}
