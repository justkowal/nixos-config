{
  config,
  lib,
  ...
}: let
  cfg = config.lab.keymap;
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
      };
    });
  };

  config = {
    assertions = [
      {
        assertion = lib.length (lib.unique (map id cfg.entries)) == lib.length cfg.entries;
        message = "lab.keymap.entries contains a duplicate mods+key pair";
      }
    ];

    wayland.windowManager.hyprland.extraConfig =
      lib.concatMapStringsSep "\n" (e: "bind = ${e.mods}, ${e.key}, exec, ${e.exec}") cfg.entries;

    xdg.configFile."lab/keymap.json".text = builtins.toJSON cfg.entries;
  };
}
