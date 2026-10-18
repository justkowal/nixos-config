# Home configuration for the thin client boot entry (hosts/laptop/thin-client.nix): labwc, the island, a
# small bar, the palette, Moonlight and the accubattery daemon, nothing else.
{
  config,
  pkgs,
  lib,
  ...
}: let
  tokens = config.lab.design.tokens;
  accubattery = pkgs.callPackage ../pkgs/accubattery {};
  stream = config.lab.thin.stream;

  # wake the desktop (toast included), then stream it
  connect = pkgs.writeShellApplication {
    name = "thin-connect";
    runtimeInputs = [config.lab.cli.package pkgs.moonlight-qt];
    text = ''
      lab run ${stream.host}
      exec moonlight stream ${stream.address} ${lib.escapeShellArg stream.app}
    '';
  };

  # volume and brightness keys, shown by the island through the bus
  volume = pkgs.writeShellApplication {
    name = "thin-volume";
    runtimeInputs = [pkgs.wireplumber pkgs.gawk config.lab.shell.package];
    text = ''
      case "''${1:-}" in
        up) wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+ ;;
        down) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
        mute) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
      esac
      line=$(wpctl get-volume @DEFAULT_AUDIO_SINK@)
      value=$(echo "$line" | awk '{printf "%d", $2 * 100}')
      muted=false
      case "$line" in *MUTED*) muted=true ;; esac
      lab-publish volume.changed --source thin --payload "{\"value\": $value, \"muted\": $muted}"
    '';
  };
  brightness = pkgs.writeShellApplication {
    name = "thin-brightness";
    runtimeInputs = [pkgs.brightnessctl config.lab.shell.package];
    text = ''
      case "''${1:-}" in
        up) brightnessctl -q set 5%+ ;;
        down) brightnessctl -q set 5%- ;;
      esac
      value=$(brightnessctl -m | cut -d, -f4 | tr -d '%')
      lab-publish brightness.changed --source thin --payload "{\"value\": $value}"
    '';
  };

  # palette entries for Wi-Fi, audio routing and the tailnet, nothing more than the palette is drawn
  thinEntries = pkgs.writeShellApplication {
    name = "lab-thin";
    runtimeInputs = [pkgs.python3 pkgs.networkmanager pkgs.wireplumber pkgs.foot config.lab.cli.package];
    text = ''
      exec python3 ${./scripts/lab-thin.py} "$@"
    '';
  };

  rcXml = ''
    <?xml version="1.0"?>
    <labwc_config>
      <core><gap>0</gap></core>
      <theme>
        <cornerRadius>${toString tokens.radius.md}</cornerRadius>
        <font place="" name="${tokens.type.ui}" size="10" />
      </theme>
      <keyboard>
        <default />
        <keybind key="W-space"><action name="Execute" command="lab-publish palette.toggle --source keymap --priority high" /></keybind>
        <keybind key="W-Return"><action name="Execute" command="foot" /></keybind>
        <keybind key="W-m"><action name="Execute" command="thin-connect" /></keybind>
        <keybind key="W-q"><action name="Close" /></keybind>
        <keybind key="XF86AudioRaiseVolume"><action name="Execute" command="thin-volume up" /></keybind>
        <keybind key="XF86AudioLowerVolume"><action name="Execute" command="thin-volume down" /></keybind>
        <keybind key="XF86AudioMute"><action name="Execute" command="thin-volume mute" /></keybind>
        <keybind key="XF86MonBrightnessUp"><action name="Execute" command="thin-brightness up" /></keybind>
        <keybind key="XF86MonBrightnessDown"><action name="Execute" command="thin-brightness down" /></keybind>
      </keyboard>
      <windowRules>
        <windowRule identifier="com.moonlight_stream.Moonlight"><action name="ToggleFullscreen" /></windowRule>
      </windowRules>
    </labwc_config>
  '';
in {
  imports = [
    ./lab/design.nix
    ./lab/keymap.nix
    ./lab/scenes.nix
    ./lab/scenes.nix
    ./lab/palette.nix
    ./lab/roster.nix
    ./lab/shell.nix
    ./lab/cli.nix
    ./lab/bar.nix
  ];

  options.lab = {
    # the lab CLI reads the focus hub address, this boot entry has no focus mode but keeps the CLI whole
    focus.hooksUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://nixos-rpi4.lab:9100/hooks";
    };
    thin.stream = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "desktop";
        description = "Short name from lab.continuity.names of the machine to stream.";
      };
      address = lib.mkOption {
        type = lib.types.str;
        default = "nixos-desktop.lab";
      };
      app = lib.mkOption {
        type = lib.types.str;
        default = "Desktop";
        description = "Name of the Sunshine application that shows the whole desktop.";
      };
    };
  };

  config = {
    home.username = "justkowal";
    home.homeDirectory = "/home/justkowal";
    home.stateVersion = "26.05";
    programs.home-manager.enable = true;

    # no scenes here: the default ones drive focus mode and rooms, which this boot entry does not have
    lab.scenes = lib.mkForce {};

    home.packages = [connect volume brightness accubattery pkgs.moonlight-qt thinEntries];

    # labd draws the island and the bar. The bar has no workspaces here, only what a thin client needs.
    lab.bar = {
      enable = true;
      default = "waybar";
      left = [];
      center = [["clock"]];
      right = [["tray"] ["battery" "network" "volume" "bluetooth"]];
    };
    # the bar window starts visible, this entry has no Waybar to switch to
    xdg.configFile."lab/bar.json".text = lib.mkForce (builtins.toJSON {
      enable = true;
      visible = true;
      edge = 8;
      height = 32;
      inherit (config.lab.bar) left center right;
    });

    # the machines `lab run` and the palette know about, and how to wake the desktop
    xdg.configFile."lab/continuity.json".text = builtins.toJSON {
      names = {
        thinkpad-t14s-gen1-amd = "laptop";
        nixos-desktop = "desktop";
      };
      wake.nixos-desktop = "wakeonlan 10:ff:e0:40:7d:6e";
      notifications = false;
      ignore = [];
      fingerprint = false;
      clipboard = false;
    };

    lab.palette.entries = [
      {
        title = "Stream the desktop";
        group = "Thin client";
        exec = "thin-connect";
      }
      {
        title = "Suspend";
        group = "System";
        exec = "systemctl suspend";
      }
      {
        title = "Reboot";
        group = "System";
        exec = "systemctl reboot";
        confirm = true;
      }
      {
        title = "Power off";
        group = "System";
        exec = "systemctl poweroff";
        confirm = true;
      }
    ];

    xdg.configFile."labwc/rc.xml".text = rcXml;
    xdg.configFile."labwc/autostart" = {
      executable = true;
      text = ''
        dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
        systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
        systemctl --user start labd.service accubattery-daemon.service
      '';
    };
    xdg.configFile."labwc/environment".text = ''
      XDG_CURRENT_DESKTOP=labwc
      QT_QPA_PLATFORM=wayland
      MOZ_ENABLE_WAYLAND=1
    '';

    systemd.user.services.accubattery-daemon = {
      Unit.Description = "AccuBattery session detector, telemetry logger and charge alarm";
      Service = {
        ExecStart = "${accubattery}/bin/accubattery daemon";
        Environment = "PATH=${lib.makeBinPath (with pkgs; [coreutils procps systemd])}:${accubattery}/bin:/run/current-system/sw/bin";
        Restart = "on-failure";
        RestartSec = 10;
      };
    };
  };
}
