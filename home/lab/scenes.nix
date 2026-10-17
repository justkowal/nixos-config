{
  config,
  lib,
  ...
}: let
  cfg = config.lab.scenes;
in {
  options.lab.scenes = lib.mkOption {
    default = {};
    description = ''
      Named desk states. `lab scene NAME` runs the steps in order, publishes scene.started and
      scene.done, and every scene is listed in the command palette. `on` lists bus events that
      start the scene by themselves.
    '';
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        title = lib.mkOption {type = lib.types.str;};
        steps = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Shell commands, run in order. A failing step does not stop the scene.";
        };
        on = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = ["handoff.arrived"];
        };
        announce = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Show the scene in the island. Turn off when the steps already show their own state.";
        };
      };
    });
  };

  config = {
    lab.scenes = {
      arrive = {
        title = lib.mkDefault "Welcome back";
        steps = lib.mkDefault [];
      };
      focus = {
        title = lib.mkDefault "Focus";
        steps = lib.mkDefault ["focus on 25"];
        announce = lib.mkDefault false;
      };
      leave = {
        title = lib.mkDefault "Leave";
        steps = lib.mkDefault ["room save last --all" "focus off" "loginctl lock-session"];
        announce = lib.mkDefault false;
      };
    };

    xdg.configFile."lab/scenes.json".text = builtins.toJSON cfg;
  };
}
