{
  config,
  pkgs,
  lib,
  laptop ? false,
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
  # The stage: a headless labwc with Hyprland nested in it, run by the lingering user manager so a booted
  # machine can open and stream windows with nobody logged in. A live session, when there is one, is
  # preferred by lab-peer and the stage idles behind it. It has no real output, so no screen is exposed.
  stageHyprland = pkgs.writeText "lab-stage-hyprland.conf" ''
    # fixed rules: without them Hyprland re-applies an automatic scale of 2 when another headless output appears,
    # which breaks the pointer mapping of lab-peer
    monitor = LAB-STAGE, 1920x1080@60, 0x0, 1
    monitor = , preferred, auto, 1
    misc {
      disable_hyprland_logo = true
      disable_splash_rendering = true
      vfr = true
    }
    animations {
      enabled = false
    }
    debug {
      disable_logs = true
    }
  '';
  # the stage has no keyboard to copy a keymap from, lab-inject uses this one (Polish programmer layout)
  stageKeymap = pkgs.runCommand "lab-stage-keymap" {nativeBuildInputs = [pkgs.libxkbcommon];} ''
    xkbcli compile-keymap --layout pl > $out
  '';
  stageLabwc = pkgs.writeTextDir "rc.xml" ''<?xml version="1.0"?><labwc_config/>'';

  # the nested Hyprland needs the socket of our labwc, not the one of a live session
  stageRun = pkgs.writeShellApplication {
    name = "lab-stage-hypr";
    runtimeInputs = [pkgs.iproute2 pkgs.coreutils pkgs.gnugrep];
    text = ''
      pid=$(systemctl --user show lab-stage -p MainPID --value)
      sock=""
      for _ in $(seq 100); do
        sock=$(ss -xlpn | grep "pid=$pid," | grep -o 'wayland-[0-9]*' | head -1 || true)
        [ -n "$sock" ] && break
        sleep 0.1
      done
      [ -n "$sock" ] || { echo "no wayland socket for labwc $pid" >&2; exit 1; }
      export WAYLAND_DISPLAY=$sock
      exec /run/current-system/sw/bin/Hyprland -c ${stageHyprland}
    '';
  };

  # a nested Hyprland starts with no output, give it a headless one
  stageOutput = pkgs.writeShellApplication {
    name = "lab-stage-output";
    runtimeInputs = [pkgs.jq pkgs.coreutils];
    text = ''
      sig=""
      for _ in $(seq 100); do
        # shellcheck disable=SC2016
        sig=$(/run/current-system/sw/bin/hyprctl instances -j | jq -r --arg pid "$MAINPID" '.[] | select((.pid | tostring) == $pid) | .instance' || true)
        [ -n "$sig" ] && break
        sleep 0.1
      done
      export HYPRLAND_INSTANCE_SIGNATURE=$sig
      /run/current-system/sw/bin/hyprctl output create headless LAB-STAGE
    '';
  };
in {
  options.lab.peek.sessionless = lib.mkOption {
    type = lib.types.bool;
    default = !laptop;
    description = "Run the headless stage so this machine answers Peek and Run on machine with nobody logged in. Needs users.users.<name>.linger on the NixOS side.";
  };

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
          "PATH=${lib.makeBinPath [pkgs.ffmpeg pkgs.glib.bin pkgs.pulseaudio peek config.lab.shell.package]}:/etc/profiles/per-user/${user}/bin:/run/current-system/sw/bin"
          "TAILSCALE=/run/current-system/sw/bin/tailscale"
          "LIBVA_DRIVERS_PATH=/run/opengl-driver/lib/dri"
        ] ++ lib.optional cfg.sessionless "LAB_INJECT_KEYMAP=${stageKeymap}";
        Restart = "always";
        RestartSec = 5;
      };
      # with the stage it runs from boot, without it only inside a login
      Install.WantedBy =
        if cfg.sessionless
        then ["default.target"]
        else ["graphical-session.target"];
    };

    systemd.user.services.lab-stage = lib.mkIf cfg.sessionless {
      Unit.Description = "Kowal Lab headless stage compositor";
      Service = {
        Environment = ["WLR_BACKENDS=headless" "WLR_LIBINPUT_NO_DEVICES=1" "WLR_RENDERER=gles2"];
        ExecStart = "${pkgs.labwc}/bin/labwc -C ${stageLabwc}";
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install.WantedBy = ["default.target"];
    };

    systemd.user.services.lab-stage-hypr = lib.mkIf cfg.sessionless {
      Unit = {
        Description = "Kowal Lab headless stage, Hyprland";
        Requires = ["lab-stage.service"];
        After = ["lab-stage.service"];
        PartOf = ["lab-stage.service"];
      };
      Service = {
        ExecStart = "${stageRun}/bin/lab-stage-hypr";
        ExecStartPost = "${stageOutput}/bin/lab-stage-output";
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install.WantedBy = ["default.target"];
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
