{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.lab.rooms;

  room = pkgs.writeShellApplication {
    name = "room";
    runtimeInputs = (with pkgs; [python3 hyprland rofi]) ++ [config.lab.cli.package];
    text = ''exec python3 ${./scripts/room.py} "$@"'';
  };
in {
  options.lab.rooms.enable = lib.mkEnableOption "project rooms (save and reopen Hyprland workspace layouts)";

  config = lib.mkIf cfg.enable {
    home.packages = [room];

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
