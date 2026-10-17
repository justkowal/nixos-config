{
  config,
  lib,
  ...
}: let
  cfg = config.lab.design;
in {
  options.lab.design = {
    tokens = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      description = "Fixed design tokens. Colour is not here: it comes from Matugen.";
    };
    reducedMotion = lib.mkEnableOption "reduced motion for every Lab surface";
    soundEnabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Scene and handoff sounds. System mute still applies.";
    };
    textScale = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
    };
  };

  config = {
    lab.design.tokens = {
      type = {
        ui = "Outfit";
        # swap for a dot-matrix face once one is picked; numerals only
        display = "JetBrainsMono Nerd Font";
        mono = "JetBrainsMono Nerd Font";
        sizes = {
          caption = 9;
          body = 13;
          title = 16;
          display = 64;
        };
      };
      radius = {
        sm = 8;
        md = 12;
        lg = 18;
        xl = 24;
      };
      space = [4 8 12 16 24 32];
      motion = {
        duration = {
          fast = 120;
          base = 220;
          slow = 360;
        };
        spring = {
          stiffness = 320.0;
          damping = 26.0;
          mass = 1.0;
        };
      };
      material = {
        blur = {
          bar = 1;
          overlay = 2;
        };
        alpha = {
          surface = 0.92;
          overlay = 0.85;
        };
      };
      # freedesktop sound theme names, played through canberra
      sound = {
        scene = "complete";
        handoff = "message-new-instant";
        arrive = "service-login";
        leave = "service-logout";
      };
      glyph = {
        focus = "focus";
        room = "layout-grid";
        handoff = "arrow-left-right";
        battery = "battery";
        ci = "git-pull-request";
        tariff = "zap";
        scene = "sparkles";
      };
    };

    xdg.configFile."lab/tokens.json".text = builtins.toJSON (cfg.tokens
      // {
        inherit (cfg) reducedMotion soundEnabled textScale;
      });
  };
}
