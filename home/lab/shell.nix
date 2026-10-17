{
  config,
  pkgs,
  lib,
  ...
}: let
  labd = pkgs.callPackage ../../pkgs/labd {};
in {
  options.lab.shell.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "labd: the state bus, the island, and the lab-publish client.";
  };

  config = {
    lab.shell.package = labd;
    home.packages = [labd];

    lab.keymap.entries = [
      {
        mods = "SUPER";
        key = "SPACE";
        exec = "lab publish palette.toggle --source keymap --priority high";
        group = "Shell";
        label = "Command palette";
        palette = false;
      }
    ];

    systemd.user.services.labd = {
      Unit = {
        Description = "Kowal Lab state bus and island";
        PartOf = ["graphical-session.target"];
        After = ["graphical-session.target"];
      };
      Service = {
        ExecStart = lib.getExe labd;
        # the palette runs room and the user's tools
        Environment = ["PATH=/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"];
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = ["graphical-session.target"];
    };

    wayland.windowManager.hyprland.extraConfig = ''
      layerrule = blur 1, match:namespace ^(labd-island)$
      layerrule = ignore_alpha 0.3, match:namespace ^(labd-island)$
      layerrule = no_anim 1, match:namespace ^(labd-island)$
      layerrule = blur 1, match:namespace ^(labd-palette)$
      layerrule = ignore_alpha 0.3, match:namespace ^(labd-palette)$
      layerrule = no_anim 1, match:namespace ^(labd-palette)$
    '';
  };
}
