{
  config,
  pkgs,
  lib,
  laptop ? false,
  ...
}: let
  sys-info = pkgs.writeShellApplication {
    name = "sys-info";
    runtimeInputs = with pkgs; [jq findutils gnugrep gawk coreutils];
    text = builtins.readFile ./scripts/sys-info.sh;
  };

  pomodoro = pkgs.writeShellApplication {
    name = "pomodoro";
    runtimeInputs = with pkgs; [jq coreutils libnotify];
    text = builtins.readFile ./scripts/pomodoro.sh;
  };

  pip-toggle = pkgs.writeShellApplication {
    name = "pip-toggle";
    runtimeInputs = with pkgs; [jq hyprland coreutils];
    text = builtins.readFile ./scripts/pip-toggle.sh;
  };

  fleet-status = pkgs.writeShellApplication {
    name = "fleet-status";
    runtimeInputs = with pkgs; [jq iputils curl gawk coreutils];
    checkPhase = "";
    text = builtins.readFile ./scripts/fleet-status.sh;
  };

  fleet-menu = pkgs.writeShellApplication {
    name = "fleet-menu";
    runtimeInputs = with pkgs; [rofi xdg-utils kitty libnotify openssh coreutils];
    checkPhase = "";
    text = builtins.readFile ./scripts/fleet-menu.sh;
  };
in {
  home.packages = [sys-info pomodoro pip-toggle fleet-status fleet-menu];

  programs.waybar = {
    enable = true;
    systemd = {
      enable = true;
      targets = ["graphical-session.target"];
    };
    settings = [
      {
        layer = "top";
        position = "top";
        height =
          if laptop
          then 32
          else 36;
        margin-top =
          if laptop
          then 6
          else 8;
        margin-left =
          if laptop
          then 8
          else 12;
        margin-right =
          if laptop
          then 8
          else 12;
        modules-left = ["hyprland/workspaces" "hyprland/submap"];
        modules-center = ["clock" "custom/pomodoro" "clock#date"];
        modules-right =
          if laptop
          then ["battery" "backlight" "network" "bluetooth" "pulseaudio" "custom/fleet" "custom/controlcenter" "custom/thinkdot" "custom/notification" "custom/power" "tray"]
          else ["mpris" "custom/fleet" "group/system" "group/hardware" "pulseaudio" "custom/pip" "custom/controlcenter" "custom/notification" "custom/power"];

        "hyprland/workspaces" = {
          disable-scroll = true;
          all-outputs = true;
          format = "{name}";
        };

        "clock" = {format = "{:%H:%M}";};

        "clock#date" = {
          format = "{:%d.%m.%Y}";
          tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
          on-click = "env XDG_CURRENT_DESKTOP=GNOME ${pkgs.gnome-calendar}/bin/gnome-calendar";
        };

        battery = {
          states = {
            warning = 30;
            critical = 15;
          };
          format = "{icon} {capacity}%";
          format-charging = "󰂄 {capacity}%";
          format-plugged = "󰚥 {capacity}%";
          format-full = "󰁹 {capacity}%";
          format-icons = ["󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹"];
          tooltip-format = "{timeTo} ({power:0.1f}W)\nHealth: {health}%";
        };

        backlight = {
          device = "amdgpu_bl1";
          format = "{icon} {percent}%";
          format-icons = ["󰃞" "󰃟" "󰃠"];
          on-scroll-up = "${pkgs.brightnessctl}/bin/brightnessctl set 5%+ -q";
          on-scroll-down = "${pkgs.brightnessctl}/bin/brightnessctl set 5%- -q";
          tooltip-format = "Brightness: {percent}%";
        };

        bluetooth = {
          format = "󰂯 {status}";
          format-connected = "󰂱 {device_alias}";
          format-connected-battery = "󰂱 {device_alias} ({device_battery_percentage}%)";
          tooltip-format = "{controller_alias}\t{controller_address}\n\n{num_connections} connected";
          tooltip-format-connected = "{controller_alias}\t{controller_address}\n\n{num_connections} connected\n\n{device_enumerate}";
          tooltip-format-enumerate-connected = "{device_alias}\t{device_address}";
          on-click = "${pkgs.blueman}/bin/blueman-manager";
        };

        "mpris" = {
          format = "{player_icon} {title} - {artist}";
          format-paused = "{status_icon} <i>{title} - {artist}</i>";
          player-icons = {
            default = "󰎆 ";
            spotify = " ";
          };
          status-icons = {paused = "󰏤 ";};
          on-click = "playerctl play-pause";
          on-click-right = "playerctl next";
          on-click-middle = "playerctl previous";
          max-length = 35;
        };

        "idle_inhibitor" = {
          format = "{icon}";
          format-icons = {
            activated = "󰅶 ";
            deactivated = "󰾆 ";
          };
        };

        "disk" = {
          interval = 30;
          format = "󰋊 {percentage_used}%";
          path = "/";
        };
        "pulseaudio" = {
          format = "󰕾 {volume}%";
          format-muted = "󰖁 Muted";
          on-click = "pwvucontrol";
        };

        "network" = {
          format-wifi = "󰖩 {essid}";
          format-ethernet = "󰈀 Wired";
          format-disconnected = "󰖪 Disconnected";
          tooltip-format = "{ifname} via {gwaddr}";
          on-click = "kitty --class network_tui -e nmtui";
        };

        "custom/sysinfo" = {
          exec = "${sys-info}/bin/sys-info";
          interval = 2;
          return-type = "json";
          format = "{}";
        };

        "memory" = {format = "󰍛 {percentage}%";};

        "custom/update" = {
          exec = pkgs.writeShellScript "check-update" ''
            if [ -d /var/tmp/nixos-pending-update ] && [ -f /var/tmp/nixos-pending-update.ready ]; then
              ${pkgs.jq}/bin/jq -n -c --arg text "󰚰 Update Ready" --arg class "ready" --arg tooltip "Pre-built update staged!&#x0a;Click to review package diff and switch." '{text: $text, class: $class, tooltip: $tooltip}'
            else
              if [ -f /var/tmp/nixos-pending-update.ready ]; then
                rm -f /var/tmp/nixos-pending-update /var/tmp/nixos-pending-update.ready /var/tmp/nixos-pending-update.diff
              fi
              ${pkgs.jq}/bin/jq -n -c --arg text "󰚰" --arg class "idle" --arg tooltip "NixOS Auto-Updater Idle / Up to date.&#x0a;Click to check & stage update now." '{text: $text, class: $class, tooltip: $tooltip}'
            fi
          '';
          interval = 10;
          return-type = "json";
          on-click = pkgs.writeShellScript "handle-update-click" ''
            if [ -d /var/tmp/nixos-pending-update ] && [ -f /var/tmp/nixos-pending-update.ready ]; then
              kitty --class update_review -e nixos-update-apply
            else
              kitty --class update_stage -e nixos-update-stage
            fi
          '';
          signal = 8;
        };

        "custom/notification" = {
          tooltip = false;
          format = "{icon}";
          format-icons = {
            notification = "󱅫";
            none = "󰂚";
            dnd-notification = "󰂛";
            dnd-none = "󰂛";
          };
          return-type = "json";
          exec = "${pkgs.swaynotificationcenter}/bin/swaync-client -swb";
          on-click = "${pkgs.swaynotificationcenter}/bin/swaync-client -t -sw";
          on-click-right = "${pkgs.swaynotificationcenter}/bin/swaync-client -d -sw";
          escape = true;
        };

        "custom/thinkdot" = {
          format = "{}";
          return-type = "json";
          exec = "thinkdot waybar";
          interval = 2;
          on-click = "thinkdot stealth toggle";
          tooltip = true;
        };

        "custom/fleet" = {
          format = "{}";
          return-type = "json";
          exec = "${fleet-status}/bin/fleet-status";
          interval = 10;
          on-click = "${pkgs.xdg-utils}/bin/xdg-open https://lab";
          on-click-right = "${fleet-menu}/bin/fleet-menu";
          on-click-middle = "${fleet-status}/bin/fleet-status probe";
          tooltip = true;
        };

        "custom/homelab" = {
          format = "{}";
          return-type = "json";
          exec = "${fleet-status}/bin/fleet-status";
          interval = 10;
          on-click = "${pkgs.xdg-utils}/bin/xdg-open https://lab";
          on-click-right = "${fleet-menu}/bin/fleet-menu";
          tooltip = true;
        };

        "custom/controlcenter" = {
          format = "󰕮";
          tooltip = true;
          tooltip-format = "Control Center (Super+C)";
          on-click = "control-center-gui";
        };

        "custom/power" = {
          format = "󰐥 ";
          on-click = "power-menu";
        };

        "custom/pomodoro" = {
          format = "{}";
          return-type = "json";
          exec = "pomodoro status";
          interval = 1;
          on-click = "pomodoro toggle";
          on-click-middle = "pomodoro reset";
          on-click-right = "pomodoro skip";
        };

        "custom/pip" = {
          exec = "pip-toggle";
          interval = 1;
          return-type = "json";
          format = "{}";
          on-click = "pip-toggle toggle";
        };

        "custom/hw_trigger" = {
          format = "󰻠";
          tooltip = false;
        };

        "custom/sys_trigger" = {
          format = "󰒓";
          tooltip = false;
        };

        "group/hardware" = {
          orientation = "inherit";
          drawer = {
            transition-duration = 500;
            transition-left-to-right = false;
            click-to-reveal = true;
          };
          modules = [
            "custom/hw_trigger"
            "custom/sysinfo"
            "memory"
            "disk"
          ];
        };

        "group/system" = {
          orientation = "inherit";
          drawer = {
            transition-duration = 500;
            transition-left-to-right = false;
            click-to-reveal = true;
          };
          modules = [
            "custom/sys_trigger"
            "network"
            "custom/update"
            "idle_inhibitor"
            "tray"
          ];
        };
      }
    ];

    style = ''
      @import url("colors.css");

      * {
        font-family: "Outfit", "JetBrainsMono Nerd Font", sans-serif;
        font-size: ${
        if laptop
        then "12px"
        else "13px"
      };
        font-weight: bold;
        border: none;
        border-radius: 0;
      }

      window#waybar {
        background-color: alpha(@background, 0.90);
        border: 1px solid alpha(@outline, 0.40);
        border-radius: 18px;
        color: @on_background;
        transition-property: background-color;
        transition-duration: .3s;
        padding: 0;
      }

      .modules-left { margin-left: 12px; }
      .modules-right { margin-right: 12px; }

      #workspaces button {
        padding: 0 10px;
        color: @on_surface_variant;
        background-color: transparent;
        border-radius: 10px;
        margin: 4px 2px;
      }

      #workspaces button.active {
        color: @primary;
        background-color: alpha(@primary_container, 0.65);
      }

      #clock, #pulseaudio, #custom-sysinfo, #memory, #mpris, #idle_inhibitor, #network, #disk, #custom-notification, #custom-thinkdot, #custom-power, #custom-pomodoro, #custom-update, #custom-pip, #custom-fleet, #custom-homelab, #custom-hw_trigger, #custom-sys_trigger, #backlight, #bluetooth {
        padding: 0 14px;
        margin: 4px 2px;
        background-color: alpha(@surface_variant, 0.45);
        border-radius: 12px;
      }

      #battery {
        padding: 0 14px;
        margin: 4px 2px;
        background-color: alpha(@surface_variant, 0.45);
        border-radius: 12px;
        color: @primary;
      }

      window#waybar group.hardware, window#waybar group.system {
        background-color: transparent;
      }

      #custom-hw_trigger, #custom-sys_trigger {
        color: @primary;
        font-size: 15px;
      }

      #custom-notification { color: @primary; }
      #custom-thinkdot { color: @error; font-size: 15px; }
      #custom-thinkdot.stealth { color: @outline; }
      #custom-thinkdot.privacy { color: @error; font-weight: bold; }
      #custom-thinkdot.focus { color: @primary; }
      #custom-thinkdot.break { color: @secondary; }
      #custom-thinkdot.critical { color: @error; }
      #custom-thinkdot.idle { color: @on_surface_variant; }
      #custom-update { color: @tertiary; }
      #custom-update.ready { color: @primary; background-color: alpha(@primary, 0.25); }
      #custom-pomodoro.work { color: @error; }
      #custom-pomodoro.break { color: @primary; }
      #custom-pomodoro.paused { color: @on_surface_variant; }
      #custom-pip { color: @secondary; }
      #custom-pip.hidden { color: @on_surface_variant; }
      #battery.warning { color: @tertiary; }
      #battery.critical { color: @error; }

      #submap {
        padding: 0 12px;
        margin: 4px 2px;
        background-color: alpha(@primary_container, 0.70);
        color: @primary;
        border: 1px solid alpha(@primary, 0.50);
        border-radius: 12px;
      }

      #mpris { color: @secondary; }
      #mpris.playing { color: @primary; }
      #mpris.paused { color: @on_surface_variant; }
      #clock { color: @on_background; font-size: 14px; }
      #pulseaudio { color: @secondary; }
      #network { color: @secondary; }
      #backlight { color: @tertiary; }
      #bluetooth { color: @primary; }
      #custom-sysinfo { color: @primary; }
      #idle_inhibitor { color: @tertiary; }
      #memory { color: @primary; }
      #disk { color: @primary; }
      #custom-fleet, #custom-homelab { color: @primary; font-weight: bold; }
      #custom-fleet.online, #custom-homelab.online { color: @primary; }
      #custom-fleet.partial { color: @tertiary; }
      #custom-fleet.warning, #custom-homelab.offline { color: @error; }
      #custom-controlcenter { color: @primary; font-size: 15px; }
      #custom-power { color: @error; }
      #tray { margin: 4px 2px; padding: 0 10px; }
    '';
  };

  services.swaync = {
    enable = true;
    settings = {
      positionX = "right";
      positionY = "top";
      control-center-margin-top = if laptop then 8 else 12;
      control-center-margin-bottom = if laptop then 12 else 20;
      control-center-margin-right = if laptop then 10 else 16;
      control-center-width = if laptop then 360 else 420;
      control-center-height = if laptop then 560 else 660;
      fit-to-screen = false;
      layer = "top";
    };
    style = ''
      @import "colors.css";

      * {
        font-family: "Outfit", "JetBrainsMono Nerd Font", sans-serif;
        font-size: 13px;
      }

      .control-center {
        background-color: alpha(@background, 0.88);
        border: 1px solid alpha(@outline, 0.35);
        border-radius: 18px;
        padding: 14px;
        margin: 10px 14px 16px 14px;
      }

      .notification {
        background-color: alpha(@surface_variant, 0.85);
        border: 1px solid alpha(@outline, 0.75);
        border-radius: 14px;
        color: @on_background;
        padding: 10px;
        margin: 6px;
      }

      .notification-content { margin: 5px; }
      .notification-title { font-weight: bold; color: @primary; }
      .notification-body { color: @on_surface; }
    '';
  };
}
