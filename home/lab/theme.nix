{
  config,
  lib,
  ...
}: let
  cfg = config.lab.theme;
  pack = lib.types.submodule {
    options = {
      title = lib.mkOption {type = lib.types.str;};
      mode = lib.mkOption {
        type = lib.types.enum ["dark" "light" "auto"];
        default = "dark";
        description = "auto follows the wallpaper: a light wallpaper gives a light scheme.";
      };
      scheme = lib.mkOption {
        type = lib.types.str;
        default = "scheme-tonal-spot";
        description = "Matugen scheme type, for example scheme-monochrome or scheme-expressive.";
      };
      tokens = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Overrides merged over lab.design.tokens. Same shape, only the keys that change.";
      };
    };
  };
in {
  options.lab.theme = {
    default = lib.mkOption {
      type = lib.types.str;
      default = "lab";
      description = "Pack used until `lab theme NAME` picks another.";
    };
    packs = lib.mkOption {
      type = lib.types.attrsOf pack;
      default = {};
      description = "Theme packs. Colour still comes from Matugen, a pack only chooses its mode and scheme.";
    };
  };

  config = {
    lab.theme.packs = {
      lab = {
        title = lib.mkDefault "Lab";
      };
      nothing = {
        title = lib.mkDefault "Dot matrix";
        scheme = lib.mkDefault "scheme-monochrome";
        tokens = {
          radius = {
            sm = 2;
            md = 4;
            lg = 8;
            xl = 12;
          };
          material.alpha = {
            surface = 1.0;
            overlay = 1.0;
          };
          motion.spring = {
            stiffness = 520.0;
            damping = 42.0;
          };
        };
      };
      soft = {
        title = lib.mkDefault "Soft";
        mode = lib.mkDefault "auto";
        scheme = lib.mkDefault "scheme-expressive";
        tokens = {
          radius = {
            sm = 12;
            md = 16;
            lg = 24;
            xl = 32;
          };
          material.alpha = {
            surface = 0.82;
            overlay = 0.72;
          };
          motion.spring = {
            stiffness = 220.0;
            damping = 20.0;
          };
        };
      };
    };

    xdg.configFile."lab/themes.json".text = builtins.toJSON {
      inherit (cfg) default packs;
    };

    lab.palette.entries =
      lib.mapAttrsToList (name: p: {
        title = "Theme: ${p.title}";
        group = "Desktop";
        exec = "lab theme ${name}";
      })
      cfg.packs;

    lab.keymap.entries = [
      {
        mods = "$mod ALT";
        key = "C";
        exec = "lab theme --next";
        group = "Desktop";
        label = "Next theme pack";
      }
    ];
  };
}
