{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.lab.rooms;

  peerTitle = config.lab.roster.devices.${cfg.peer}.title or cfg.peer;

  room = pkgs.writeShellApplication {
    name = "room";
    runtimeInputs = (with pkgs; [python3 hyprland rofi]) ++ [config.lab.cli.package];
    text = ''
      export ROOM_PEER=${lib.escapeShellArg cfg.peer}
      export ROOM_PEER_TITLE=${lib.escapeShellArg peerTitle}
      export TAILSCALE=/run/current-system/sw/bin/tailscale
      exec python3 ${./scripts/room.py} "$@"
    '';
  };

  inbox = pkgs.runCommand "lab-inbox-src" {} ''
    mkdir -p $out
    cp ${./scripts/lab-inbox.py} $out/lab-inbox.py
    cp ${./scripts/guis/lab_bus.py} $out/lab_bus.py
  '';
in {
  options.lab.rooms = {
    enable = lib.mkEnableOption "project rooms (save and reopen Hyprland workspace layouts)";
    peer = lib.mkOption {
      type = lib.types.str;
      default = config.lab.handoff.peer;
      description = "Tailscale name of the machine `room send` targets, and where rooms are received from.";
    };
    inbox.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Receive rooms sent from your other machines over Taildrop. They wait in the palette until you accept one.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [room];

    # needs tailscale's operator to be this user on the machine (see hosts/*/configuration.nix)
    systemd.user.services.lab-inbox = lib.mkIf cfg.inbox.enable {
      Unit = {
        Description = "Receive rooms over Taildrop";
        PartOf = ["graphical-session.target"];
        After = ["graphical-session.target" "labd.service"];
      };
      Service = {
        ExecStart = "${pkgs.python3}/bin/python3 ${inbox}/lab-inbox.py";
        Environment = ["TAILSCALE=/run/current-system/sw/bin/tailscale"];
        Restart = "on-failure";
        RestartSec = 10;
      };
      Install.WantedBy = ["graphical-session.target"];
    };

    lab.keymap.entries = [
      {
        mods = "$mod ALT";
        key = "R";
        exec = "room pick";
        group = "Rooms";
        label = "Pick room";
      }
    ];
  };
}
