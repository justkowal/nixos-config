{
  config,
  lib,
  ...
}: let
  cfg = config.lab.keymap;
  # $mod is only defined further down hyprland.nix, and lines from modules imported earlier land
  # above that definition, where an undefined $mod silently drops the modifier. Write SUPER instead.
  norm = lib.replaceStrings ["$mod"] ["SUPER"];
  entries = map (e: e // {mods = norm e.mods;}) cfg.entries;
  id = e: "${e.mods}|${e.key}";
in {
  options.lab.keymap.entries = lib.mkOption {
    default = [];
    description = "Lab keybinds. Rendered into Hyprland binds and ~/.config/lab/keymap.json.";
    type = lib.types.listOf (lib.types.submodule {
      options = {
        mods = lib.mkOption {
          type = lib.types.str;
          default = "";
          example = "$mod ALT";
        };
        key = lib.mkOption {type = lib.types.str;};
        exec = lib.mkOption {type = lib.types.str;};
        group = lib.mkOption {type = lib.types.str;};
        label = lib.mkOption {type = lib.types.str;};
        palette = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "List this bind as an entry in the command palette.";
        };
      };
    });
  };

  config = {
    assertions = [
      {
        assertion = lib.length (lib.unique (map id entries)) == lib.length entries;
        message = "lab.keymap.entries contains a duplicate mods+key pair";
      }
    ];

    wayland.windowManager.hyprland.extraConfig =
      lib.concatMapStringsSep "\n" (e: "bind = ${e.mods}, ${e.key}, exec, ${e.exec}") entries;

    xdg.configFile."lab/keymap.json".text = builtins.toJSON entries;
  };
}
