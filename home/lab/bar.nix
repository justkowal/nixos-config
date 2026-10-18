{
  config,
  lib,
  laptop ? false,
  ...
}: let
  cfg = config.lab.bar;
  labdFirst = cfg.default == "labd";
in {
  options.lab.bar = {
    enable = lib.mkEnableOption "the labd bar, drawn from the tokens next to Waybar so the two can be switched live";
    default = lib.mkOption {
      type = lib.types.enum ["waybar" "labd"];
      default = "waybar";
      description = "Which bar a new session starts with. The other one stays installed and one palette entry away.";
    };
    left = lib.mkOption {
      type = lib.types.listOf (lib.types.listOf lib.types.str);
      default = [["workspaces"]];
      description = "Capsules, each a list of module names.";
    };
    center = lib.mkOption {
      type = lib.types.listOf (lib.types.listOf lib.types.str);
      default = [["clock" "pomodoro"]];
    };
    right = lib.mkOption {
      type = lib.types.listOf (lib.types.listOf lib.types.str);
      default = [
        ["media"]
        ["tray"]
        ["focus" "fleet" "battery" "backlight" "network" "volume" "bluetooth"]
        ["caffeine" "thinkdot" "notifications" "control" "power"]
      ];
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."lab/bar.json".text = builtins.toJSON {
      enable = true;
      visible = labdFirst;
      edge =
        if laptop
        then 8
        else 12;
      height =
        if laptop
        then 32
        else 36;
      inherit (cfg) left center right;
    };

    # waybar stays installed and startable, it just stops being the session default
    systemd.user.services.waybar.Install.WantedBy = lib.mkIf labdFirst (lib.mkForce []);

    lab.palette.entries = [
      {
        title = "Bar: use the Lab bar";
        group = "Shell";
        exec = "systemctl --user stop waybar; lab publish bar.show --source palette";
      }
      {
        title = "Bar: use Waybar";
        group = "Shell";
        exec = "lab publish bar.hide --source palette; systemctl --user start waybar";
      }
    ];
  };
}
