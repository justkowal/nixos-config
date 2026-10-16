{
  config,
  pkgs,
  lib,
  ...
}: let
  labd = pkgs.callPackage ../../pkgs/labd {};
in {
  home.packages = [labd];

  systemd.user.services.labd = {
    Unit = {
      Description = "Kowal Lab state bus and island";
      PartOf = ["graphical-session.target"];
      After = ["graphical-session.target"];
    };
    Service = {
      ExecStart = lib.getExe labd;
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = ["graphical-session.target"];
  };

  wayland.windowManager.hyprland.extraConfig = ''
    layerrule = blur 1, match:namespace ^(labd-island)$
    layerrule = ignore_alpha 0.3, match:namespace ^(labd-island)$
    layerrule = no_anim 1, match:namespace ^(labd-island)$
  '';
}
