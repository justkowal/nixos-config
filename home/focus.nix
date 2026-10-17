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
    runtimeInputs = (with pkgs; [coreutils curl jq libnotify]) ++ [config.lab.cli.package];
    text = ''
      export FOCUS_HOOKS=${lib.escapeShellArg cfg.hooksUrl}
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
        description = "Light the desk for focus. The LED layer (home/lab/led.nix) loads these profiles from the focus.on and focus.off events.";
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
