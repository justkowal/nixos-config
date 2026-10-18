{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.lab.continuity;
  user = config.home.username;
  path = "PATH=/etc/profiles/per-user/${user}/bin:/run/current-system/sw/bin";

  src = pkgs.runCommand "lab-continuity-src" {} ''
    mkdir -p $out
    cp ${../scripts/lab-continuity.py} $out/lab-continuity.py
    cp ${../scripts/lab-focus-sync.py} $out/lab-focus-sync.py
    cp ${../scripts/guis/lab_bus.py} $out/lab_bus.py
  '';

  py = pkgs.python3.withPackages (ps: [ps.pygobject3]);
in {
  options.lab.continuity = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Make the machines share state: notifications, the fingerprint wait toast, and fleet focus.";
    };
    names = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        thinkpad-t14s-gen1-amd = "laptop";
        nixos-desktop = "desktop";
      };
      description = "Machines that mirror to each other, keyed by hostname, with the short name used in toasts.";
    };
    notifications = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Show this machine's desktop notifications on the others too (over Taildrop).";
      };
      ignore = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["Lab" "Focus"];
        description = "Applications whose notifications are never mirrored.";
      };
    };
    fingerprint.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Show a fingerprint toast on every machine while one waits for authentication.";
    };
    focus.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start and end the local side effects of focus when it changes on another machine.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."lab/continuity.json".text = builtins.toJSON {
      inherit (cfg) names;
      notifications = cfg.notifications.enable;
      inherit (cfg.notifications) ignore;
      fingerprint = cfg.fingerprint.enable;
    };

    systemd.user.services.lab-continuity = lib.mkIf (cfg.notifications.enable || cfg.fingerprint.enable) {
      Unit = {
        Description = "Kowal Lab notification and authentication mirror";
        After = ["graphical-session.target" "labd.service"];
        StartLimitIntervalSec = 0;
      };
      Service = {
        ExecStart = "${py}/bin/python3 ${src}/lab-continuity.py";
        Environment = [path "TAILSCALE=/run/current-system/sw/bin/tailscale" "GI_TYPELIB_PATH=${pkgs.glib.out}/lib/girepository-1.0"];
        Restart = "always";
        RestartSec = 5;
      };
      Install.WantedBy = ["graphical-session.target"];
    };

    systemd.user.services.lab-focus-sync = lib.mkIf (cfg.focus.enable && config.lab.focus.enable) {
      Unit = {
        Description = "Kowal Lab fleet focus follower";
        After = ["graphical-session.target" "labd.service"];
        StartLimitIntervalSec = 0;
      };
      Service = {
        ExecStart = "${pkgs.python3}/bin/python3 ${src}/lab-focus-sync.py";
        Environment = [path];
        Restart = "always";
        RestartSec = 5;
      };
      Install.WantedBy = ["graphical-session.target"];
    };
  };
}
