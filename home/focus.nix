{
  config,
  pkgs,
  lib,
  laptop ? false,
  ...
}: let
  cfg = config.lab.focus;

  focus = pkgs.writeShellApplication {
    name = "focus";
    runtimeInputs =
      (with pkgs; [coreutils curl jq libnotify]) ++ [config.lab.cli.package]
      ++ lib.optional cfg.openrgb.enable (pkgs.python3.withPackages (ps: [ps.openrgb-python]));
    text = ''
      export FOCUS_HOOKS=${lib.escapeShellArg cfg.hooksUrl}
      ${lib.optionalString cfg.openrgb.enable ''
        export FOCUS_OPENRGB=1
        export FOCUS_OPENRGB_ON=${lib.escapeShellArg cfg.openrgb.focusProfile}
        export FOCUS_OPENRGB_OFF=${lib.escapeShellArg cfg.openrgb.defaultProfile}
      ''}
      ${builtins.readFile ./scripts/focus.sh}
    '';
  };
in {
  options.lab.focus = {
    enable = lib.mkEnableOption "focus mode client (focus CLI, pomodoro and caffeine hooks)";

    hooksUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://nixos-rpi4.lab:9100/hooks";
    };

    openrgb = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = !laptop;
        description = "Switch OpenRGB profiles (saved on the OpenRGB server) when focus toggles.";
      };
      focusProfile = lib.mkOption {
        type = lib.types.str;
        default = "focus";
      };
      defaultProfile = lib.mkOption {
        type = lib.types.str;
        default = "default";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [focus];

    lab.keymap.entries = [
      {
        mods = "$mod ALT";
        key = "P";
        exec = "focus toggle";
        group = "Focus";
        label = "Toggle focus";
      }
    ];
  };
}
