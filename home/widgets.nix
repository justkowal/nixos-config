{
  config,
  pkgs,
  lib,
  laptop ? false,
  osConfig ? {},
  ...
}: let
  cfg = config.lab.widgets;

  typelibPath = lib.makeSearchPath "lib/girepository-1.0" (with pkgs; [
    gtk4
    libadwaita
    gtk4-layer-shell
    glib.out
    graphene
    pango.out
    gdk-pixbuf
    harfbuzz
    gobject-introspection
    evolution-data-server
    libical
    libsoup_3
    json-glib
  ]);

  tariff = osConfig.lab.tariff or null;

  settings = {
    inherit (cfg) lat lon place monitors desktop disabled;
    compact = laptop;
    flakeDir = "${config.home.homeDirectory}/nixos-config";
    textfileDir = "/var/lib/node-exporter-textfile";
    snapDir = osConfig.lab.snapshots.dir or "/home/.snapshots";
    woodpecker = {
      inherit (cfg.woodpecker) url repos;
      tokenFile = osConfig.sops.secrets.woodpecker_widget_token.path or "/run/secrets/woodpecker_widget_token";
    };
    tariff =
      if tariff == null
      then {
        name = "G12";
        windows = [];
        pricePeak = 0.0;
        priceOffPeak = 0.0;
      }
      else {
        inherit (tariff) name pricePeak priceOffPeak;
        windows = tariff.offPeakWindows;
      };
  };

  guis = pkgs.runCommand "deskwidgets-src" {} ''
    mkdir -p $out
    cp ${./scripts/guis/widgets_gui.py} $out/widgets_gui.py
    cp ${./scripts/guis/widgets_providers.py} $out/widgets_providers.py
  '';

  deskwidgets = pkgs.writeShellApplication {
    name = "deskwidgets";
    runtimeInputs = with pkgs; [
      (python3.withPackages (ps: [ps.pygobject3 ps.pycairo]))
      playerctl
      swaynotificationcenter
      gh
    ];
    text = ''
      export GI_TYPELIB_PATH="${typelibPath}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      # layer-shell has to be linked before libwayland-client, python can't guarantee that order
      export LD_PRELOAD="${pkgs.gtk4-layer-shell}/lib/libgtk4-layer-shell.so''${LD_PRELOAD:+:$LD_PRELOAD}"
      exec python3 ${guis}/widgets_gui.py --config ${pkgs.writeText "deskwidgets.json" (builtins.toJSON settings)} "$@"
    '';
  };

  toggle = "${pkgs.glib}/bin/gdbus call --session --dest lab.justkowal.Widgets --object-path /lab/justkowal/Widgets --method org.gtk.Actions.Activate toggle [] {}";
in {
  options.lab.widgets = {
    enable = lib.mkEnableOption "desktop widgets (wallpaper column + SUPER+W dashboard)";
    lat = lib.mkOption {
      type = lib.types.float;
      default = 50.06;
    };
    lon = lib.mkOption {
      type = lib.types.float;
      default = 19.94;
    };
    place = lib.mkOption {
      type = lib.types.str;
      default = "Kraków";
    };
    monitors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Connectors that get the wallpaper column (e.g. DP-1). Empty means every monitor.";
    };
    desktop = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        if laptop
        then ["agenda" "weather" "claude" "ci"]
        else ["agenda" "weather" "claude" "gemini" "ci" "media" "power"];
      description = "Sections on the wallpaper column, top to bottom. The dashboard always shows everything.";
    };
    disabled = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Providers or streams to never run (e.g. github if gh is not logged in).";
    };
    woodpecker = {
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://ci.lab";
      };
      repos = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["justkowal/nixos-configs"];
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [deskwidgets];

    systemd.user.services.deskwidgets = {
      Unit = {
        Description = "Desktop widgets";
        PartOf = ["graphical-session.target"];
        After = ["graphical-session.target"];
      };
      Service = {
        ExecStart = "${lib.getExe deskwidgets}";
        Restart = "on-failure";
        RestartSec = 3;
        # fleet-status and focus live in the user profile
        Environment = ["PATH=/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"];
      };
    };

    wayland.windowManager.hyprland.extraConfig = ''
      exec-once = systemctl --user start deskwidgets
      bind = SUPER, W, exec, ${toggle}
      layerrule = blur 1, match:namespace ^(deskwidgets-dashboard)$
      layerrule = ignore_alpha 0.3, match:namespace ^(deskwidgets-dashboard)$
      layerrule = no_anim 1, match:namespace ^(deskwidgets)$
    '';
  };
}
