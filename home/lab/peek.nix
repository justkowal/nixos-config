{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.lab.peek;
  user = config.home.username;

  src = pkgs.runCommand "lab-peek-src" {} ''
    mkdir -p $out
    cp ${../scripts/lab-peek.py} $out/lab-peek.py
    cp ${../scripts/lab-peer.py} $out/lab-peer.py
  '';

  typelibPath = lib.makeSearchPath "lib/girepository-1.0" (with pkgs; [
    gtk4
    libadwaita
    glib.out
    graphene
    pango.out
    gdk-pixbuf
    harfbuzz
    gobject-introspection
  ]);

  peek = pkgs.writeShellApplication {
    name = "lab-peek";
    runtimeInputs = [(pkgs.python3.withPackages (ps: [ps.pygobject3]))];
    text = ''
      export GI_TYPELIB_PATH="${typelibPath}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      exec python3 ${src}/lab-peek.py "$@"
    '';
  };
in {
  options.lab.peek.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.lab.continuity.enable;
    description = "Preview and poke windows on your other machines from the command palette. Needs lab.continuity.names for the machine list.";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [peek];

    # listens on the tailnet address only and answers only your own devices, see lab-peer.py
    systemd.user.services.lab-peer = {
      Unit = {
        Description = "Kowal Lab window preview for your other machines";
        After = ["graphical-session.target"];
        StartLimitIntervalSec = 0;
      };
      Service = {
        ExecStart = "${pkgs.python3}/bin/python3 ${src}/lab-peer.py";
        Environment = [
          "PATH=/etc/profiles/per-user/${user}/bin:/run/current-system/sw/bin"
          "TAILSCALE=/run/current-system/sw/bin/tailscale"
        ];
        Restart = "always";
        RestartSec = 5;
      };
      Install.WantedBy = ["graphical-session.target"];
    };

    wayland.windowManager.hyprland.extraConfig = ''
      windowrule = float 1, match:class ^(lab\.justkowal\.Peek)$
      windowrule = size 960 640, match:class ^(lab\.justkowal\.Peek)$
      windowrule = center 1, match:class ^(lab\.justkowal\.Peek)$
    '';

    lab.keymap.entries = [
      {
        mods = "$mod ALT";
        key = "W";
        exec = "lab publish palette.toggle --source keymap --priority high";
        group = "Devices";
        label = "Windows on other machines (type laptop or desktop)";
        palette = false;
      }
    ];

    lab.palette.entries = [
      {
        title = "Clipboard: pause or resume sharing";
        group = "Devices";
        exec = "lab clip toggle";
      }
    ];
  };
}
