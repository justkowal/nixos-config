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
in {
  home.packages = [sys-info pomodoro pip-toggle];

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
        modules-center =
          if laptop
          then ["clock" "clock#date"]
          else ["clock" "custom/pomodoro" "clock#date"];
        modules-right =
          if laptop
          then ["battery" "mpris" "pulseaudio" "custom/notification" "custom/power" "tray"]
          else ["mpris" "group/system" "group/hardware" "pulseaudio" "custom/pip" "custom/notification" "custom/power"];

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
          format = "󰁹 {capacity}%";
          format-charging = "󰂄 {capacity}%";
          format-plugged = "󰚥 {capacity}%";
          format-full = "󰁹 {capacity}%";
          states = {
            warning = 30;
            critical = 15;
          };
          tooltip-format = "{timeTo} remaining";
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
          format = "🔔 {icon}";
          format-icons = {
            notification = "󱅫";
            none = "󰂜";
            dnd-notification = "󰂛";
            dnd-none = "󰂛";
          };
          return-type = "json";
          exec = "${pkgs.swaynotificationcenter}/bin/swaync-client -swb";
          on-click = "${pkgs.swaynotificationcenter}/bin/swaync-client -t -sw";
          on-click-right = "${pkgs.swaynotificationcenter}/bin/swaync-client -d -sw";
          escape = true;
        };

        "custom/power" = {
          format = "⏻ ";
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
        background-color: alpha(@background, 0.68);
        border: 1px solid alpha(@outline, 0.75);
        border-radius: 20px;
        color: @on_background;
        transition-property: background-color;
        transition-duration: .5s;
        padding: 0;
      }

      .modules-left { margin-left: 12px; }
      .modules-right { margin-right: 12px; }

      #workspaces button {
        padding: 0 10px;
        color: @on_surface_variant;
        background-color: transparent;
        border-radius: 12px;
        margin: 4px 2px;
      }

      #workspaces button.active {
        color: @primary;
        background-color: @surface_variant;
      }

      #clock, #pulseaudio, #custom-sysinfo, #memory, #mpris, #idle_inhibitor, #network, #disk, #custom-notification, #custom-power, #custom-pomodoro, #custom-update, #custom-pip, #custom-hw_trigger, #custom-sys_trigger {
        padding: 0 16px;
        margin: 4px 2px;
        background-color: alpha(@surface_variant, 0.82);
        border-radius: 12px;
      }

      #battery {
        padding: 0 16px;
        margin: 4px 2px;
        background-color: alpha(@surface_variant, 0.82);
        border-radius: 12px;
        color: @primary;
      }

      window#waybar group.hardware, window#waybar group.system {
        background-color: transparent;
      }

      #custom-hw_trigger, #custom-sys_trigger {
        color: @primary;
        font-size: 15px;
        box-shadow: -16px 0px 18px -4px @background;
      }

      #custom-notification { color: @primary; }
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
        background-color: @primary;
        color: @on_primary;
        border-radius: 12px;
      }

      #mpris { color: @secondary; }
      #mpris.playing { color: @primary; }
      #mpris.paused { color: @on_surface_variant; }
      #clock { color: @on_background; font-size: 14px; }
      #pulseaudio { color: @secondary; }
      #network { color: @secondary; }
      #custom-sysinfo { color: @primary; }
      #idle_inhibitor { color: @tertiary; }
      #memory { color: @primary; }
      #disk { color: @primary; }
      #custom-power { color: @error; }
      #tray { margin: 4px 2px; padding: 0 10px; }
    '';
  };

  services.swaync = {
    enable = true;
    settings = {
      positionX = "right";
      positionY = "top";
      control-center-margin-top = 12;
      control-center-margin-bottom = 20;
      control-center-margin-right = 16;
      control-center-width = 420;
      control-center-height = 680;
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
        background-color: alpha(@background, 0.90);
        border: 1px solid alpha(@outline, 0.75);
        border-radius: 20px;
        padding: 15px;
        margin: 12px 16px 20px 16px;
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
