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
    gst_all_1.gstreamer.out
    gst_all_1.gst-plugins-base
  ]);

  # vah264dec lives in plugins-bad and the GTK4 paintable sink in plugins-rs
  gstPlugins = lib.makeSearchPath "lib/gstreamer-1.0" (with pkgs.gst_all_1; [
    gstreamer.out
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-rs
    gst-libav
  ]);

  peek = pkgs.writeShellApplication {
    name = "lab-peek";
    runtimeInputs = [(pkgs.python3.withPackages (ps: [ps.pygobject3]))];
    text = ''
      export GI_TYPELIB_PATH="${typelibPath}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      export GST_PLUGIN_SYSTEM_PATH_1_0="${gstPlugins}"
      export LIBVA_DRIVERS_PATH="''${LIBVA_DRIVERS_PATH:-/run/opengl-driver/lib/dri}"
      exec python3 ${src}/lab-peek.py "$@"
    '';
  };
in {
  options.lab.peek.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.lab.continuity.enable;
    description = "Use windows of your other machines like local ones: pick one in the command palette, get hardware decoded video and full input passthrough. Needs lab.continuity.names for the machine list.";
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
        # lab-capture grabs the window, ffmpeg encodes it on the GPU through VA-API, lab-inject presses the keys
        Environment = [
          "PATH=${lib.makeBinPath [pkgs.ffmpeg pkgs.glib.bin config.lab.shell.package]}:/etc/profiles/per-user/${user}/bin:/run/current-system/sw/bin"
          "TAILSCALE=/run/current-system/sw/bin/tailscale"
          "LIBVA_DRIVERS_PATH=/run/opengl-driver/lib/dri"
        ];
        Restart = "always";
        RestartSec = 5;
      };
      Install.WantedBy = ["graphical-session.target"];
    };

    # dialogs and popups of a remote app open as their own viewers, floating like they do over there
    wayland.windowManager.hyprland.extraConfig = ''
      windowrule = float 1, match:class ^(lab\.justkowal\.PeekDialog)$
      windowrule = center 1, match:class ^(lab\.justkowal\.PeekDialog)$
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
