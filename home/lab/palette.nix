{
  config,
  lib,
  ...
}: let
  cfg = config.lab.palette;
in {
  options.lab.palette.entries = lib.mkOption {
    default = [];
    description = "Extra command palette entries. Keymap entries are listed automatically.";
    type = lib.types.listOf (lib.types.submodule {
      options = {
        title = lib.mkOption {type = lib.types.str;};
        group = lib.mkOption {
          type = lib.types.str;
          default = "Action";
        };
        exec = lib.mkOption {type = lib.types.str;};
        confirm = lib.mkEnableOption "asking for a second Enter before running";
        glyph = lib.mkOption {
          type = lib.types.str;
          default = "action";
          description = "Glyph name from pkgs/labd/src/glyphs.rs (glyph_named in palette.rs).";
        };
      };
    });
  };

  config = {
    lab.palette.entries = [
      {
        title = "Lock screen";
        group = "System";
        exec = "loginctl lock-session";
        glyph = "lock";
      }
      {
        title = "Suspend";
        group = "System";
        exec = "loginctl lock-session && systemctl suspend";
        glyph = "power";
      }
      {
        title = "Reboot";
        group = "System";
        exec = "systemctl reboot";
        glyph = "power";
        confirm = true;
      }
      {
        title = "Power off";
        group = "System";
        exec = "systemctl poweroff";
        glyph = "power";
        confirm = true;
      }
      {
        title = "Exit Hyprland";
        group = "System";
        exec = "hyprctl dispatch exit";
        glyph = "power";
        confirm = true;
      }
      {
        title = "Cycle wallpaper and theme";
        group = "Desktop";
        exec = "change-wallpaper";
      }
    ];

    xdg.configFile."lab/palette.json".text = builtins.toJSON (
      (map (e: {
        title = e.label;
        inherit (e) group exec;
      }) (lib.filter (e: e.palette) config.lab.keymap.entries))
      ++ cfg.entries
    );
  };
}
