{
  config,
  pkgs,
  lib,
  ...
}: {
  home.username = "justkowal";
  home.homeDirectory = "/home/justkowal";
  home.enableNixpkgsReleaseCheck = false;

  # Ensure CAD/EDA directories exist for dynamic Matugen stylesheets
  home.activation = {
    createCadEdaDirs = lib.hm.dag.entryAfter ["writeBoundary"] ''
      mkdir -p /home/justkowal/.local/share/FreeCAD/v1-1/Gui/Stylesheets
      mkdir -p /home/justkowal/.config/kicad/10.0/colors
    '';
  };

  # Global developer session variables
  home.sessionVariables = {
    RUSTC_WRAPPER = "${pkgs.sccache}/bin/sccache";
    STARSHIP_CONFIG = "/home/justkowal/.config/starship.toml";
    GTK_THEME = "Adwaita:dark";
  };

  # User packages
  home.packages = with pkgs; [
    awww # Animated wallpaper daemon
    wl-clipboard # Wayland clipboard utilities
    #outfit                 # Modern sans-serif font for MD3 layouts
    playerctl # CLI media player controller
    grim # Screen grabber
    slurp # Region selector
    libnotify # Notification sender (notify-send)
    sccache # Shared compilation cache for C++/Rust
    matugen
    gnome-calendar
    gnome-control-center
    jq
    ddcutil
  ];

  # 1. Kitty Terminal configuration (Matugen dynamic themes)
  programs.kitty = {
    enable = true;
    font = {
      name = "JetBrainsMono Nerd Font";
      size = 11;
    };
    settings = {
      background_opacity = "0.85";
      enable_audio_bell = false;
      confirm_os_window_close = 0;
    };
    extraConfig = ''
      include colors.conf
    '';
  };

  # 2. Rofi Launcher (Rofi Wayland styled with Material Design 3 cards)
  programs.rofi = {
    enable = true;
    package = pkgs.rofi;
    theme = let
      # Define a custom MD3 theme inside rofi syntax
      inherit (config.lib.formats.rasi) mkLiteral;
    in {
      "@import" = "/home/justkowal/.config/rofi/colors.rasi";
      "*" = {
        width = mkLiteral "600px";
        font = "Outfit 11";
      };

      "window" = {
        background-color = mkLiteral "@bg-col";
        border = mkLiteral "2px";
        border-color = mkLiteral "@border-col";
        border-radius = mkLiteral "16px"; # Generous MD3 rounded corners
        padding = mkLiteral "20px";
      };

      "mainbox" = {
        background-color = mkLiteral "transparent";
        children = map mkLiteral ["inputbar" "listview"];
      };

      "inputbar" = {
        background-color = mkLiteral "@selected-col";
        border-radius = mkLiteral "24px"; # Pill-shaped input bar
        padding = mkLiteral "10px 15px";
        margin = mkLiteral "0px 0px 15px 0px";
        children = map mkLiteral ["prompt" "entry"];
      };

      "prompt" = {
        background-color = mkLiteral "transparent";
        text-color = mkLiteral "@accent-col";
        margin = mkLiteral "0px 10px 0px 0px";
      };

      "entry" = {
        background-color = mkLiteral "transparent";
        text-color = mkLiteral "@text-col";
      };

      "listview" = {
        background-color = mkLiteral "transparent";
        columns = 1;
        lines = 8;
        cycle = true;
      };

      "element" = {
        background-color = mkLiteral "transparent";
        text-color = mkLiteral "@text-col";
        border-radius = mkLiteral "12px";
        padding = mkLiteral "8px 12px";
        margin = mkLiteral "2px 0px";
      };

      "element-text" = {
        background-color = mkLiteral "transparent";
        text-color = mkLiteral "inherit";
      };

      "element selected" = {
        background-color = mkLiteral "@selected-col";
        text-color = mkLiteral "@accent-col";
      };
    };
  };

  # 3. Waybar Status Bar (floating, rounded pill design following MD3)
  programs.waybar = {
    enable = true;
    settings = [
      {
        layer = "top";
        position = "top";
        height = 36;
        margin-top = 8;
        margin-left = 12;
        margin-right = 12;
        modules-left = ["hyprland/workspaces" "hyprland/submap"];
        modules-center = ["clock" "custom/pomodoro" "clock#date"];
        modules-right = ["mpris" "idle_inhibitor" "disk" "custom/sysinfo" "memory" "pulseaudio" "network" "tray" "custom/power"];

        "hyprland/workspaces" = {
          disable-scroll = true;
          all-outputs = true;
          format = "{name}";
        };

        "clock" = {
          format = "{:%H:%M}";
        };

        "clock#date" = {
          format = "{:%d.%m.%Y}";
          tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
          on-click = "env XDG_CURRENT_DESKTOP=GNOME ${pkgs.gnome-calendar}/bin/gnome-calendar";
        };

        "mpris" = {
          format = "{player_icon} {title} - {artist}";
          format-paused = "{status_icon} <i>{title} - {artist}</i>";
          player-icons = {
            default = "󰎆 ";
            spotify = " ";
          };
          status-icons = {
            paused = "󰏤 ";
          };
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
          exec = "bash /home/justkowal/.config/hypr/scripts/sys_info.sh";
          interval = 2;
          return-type = "json";
          format = "{}";
        };

        "memory" = {
          format = " {percentage}%";
        };

        "custom/power" = {
          format = "⏻ ";
          on-click = "bash /home/justkowal/.config/hypr/scripts/power_menu.sh";
        };

        "custom/pomodoro" = {
          format = "{}";
          return-type = "json";
          exec = "bash /home/justkowal/.config/waybar/scripts/pomodoro.sh status";
          interval = 1;
          on-click = "bash /home/justkowal/.config/waybar/scripts/pomodoro.sh toggle";
          on-click-middle = "bash /home/justkowal/.config/waybar/scripts/pomodoro.sh reset";
          on-click-right = "bash /home/justkowal/.config/waybar/scripts/pomodoro.sh skip";
        };
      }
    ];

    # MD3 Expressive Glassmorphic Waybar Style
    style = ''
      @import url("colors.css");

      * {
        font-family: "Outfit", "JetBrainsMono Nerd Font", sans-serif;
        font-size: 13px;
        font-weight: bold;
        border: none;
        border-radius: 0;
      }

      window#waybar {
        background-color: alpha(@background, 0.68);
        border: 1px solid alpha(@outline, 0.75);
        border-radius: 20px; /* Fully rounded MD3 container */
        color: @on_background;
        transition-property: background-color;
        transition-duration: .5s;
        padding: 0;
      }

      .modules-left {
        margin-left: 12px;
      }

      .modules-right {
        margin-right: 12px;
      }

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

      #clock, #pulseaudio, #cpu, #memory, #mpris, #idle_inhibitor, #network, #disk, #custom-power, #custom-pomodoro {
        padding: 0 16px;
        margin: 4px 2px;
        background-color: alpha(@surface_variant, 0.82);
        border-radius: 12px;
      }

      #custom-pomodoro.work {
        color: @error;
      }

      #custom-pomodoro.break {
        color: @primary;
      }

      #custom-pomodoro.paused {
        color: @on_surface_variant;
      }

      #submap {
        padding: 0 12px;
        margin: 4px 2px;
        background-color: @primary;
        color: @on_primary;
        border-radius: 12px;
      }

      #mpris {
        color: @secondary;
      }

      #mpris.playing {
        color: @primary;
      }

      #mpris.paused {
        color: @on_surface_variant;
      }

      #clock {
        color: @on_background;
        font-size: 14px;
      }

      #pulseaudio {
        color: @secondary;
      }

      #network {
        color: @secondary;
      }

      #cpu {
        color: @tertiary;
      }

      #idle_inhibitor {
        color: @tertiary;
      }

      #memory {
        color: @primary;
      }

      #disk {
        color: @primary;
      }

      #custom-power {
        color: @error;
      }

      #tray {
        margin: 4px 2px;
        padding: 0 10px;
      }
    '';
  };

  # 4. Hyprland Window Manager setup (gaps, shadows, active blur, rounded borders)
  wayland.windowManager.hyprland = {
    enable = true;
    configType = "hyprlang";
    extraConfig = ''
      # 100% monitor resolution auto-detection
      monitor=,preferred,auto,1

        source = ~/.config/hypr/matugen.conf

      general {
          gaps_in = 6
          gaps_out = 12
          border_size = 2
          col.active_border = $primary $secondary 45deg
          col.inactive_border = $outline
          layout = dwindle
      }

      decoration {
          rounding = 14
          blur {
              enabled = true
              size = 3
              passes = 3
              new_optimizations = true
          }
          shadow {
              enabled = true
              range = 15
              render_power = 3
              color = rgba(11111b66)
          }
      }

      animations {
          enabled = true
          bezier = myBezier, 0.05, 0.9, 0.1, 1.05
          animation = windows, 1, 5, myBezier
          animation = windowsOut, 1, 5, default, popin 80%
          animation = border, 1, 10, default
          animation = fade, 1, 7, default
          animation = workspaces, 1, 5, default
      }

      misc {
          vrr = 1
          no_direct_scanout = false
      }

      # Autostart
      exec-once = waybar
      exec-once = awww-daemon
      # nm-applet is disabled to avoid duplicate network tray/bar icons
      # exec-once = nm-applet --indicator
      exec-once = blueman-applet
      exec-once = [workspace special:term silent] kitty --class scratchpad

      # Binds
      $mod = SUPER
      bind = $mod, RETURN, exec, kitty
      bind = $mod, grave, togglespecialworkspace, term
      bind = $mod, B, exec, firefox
      bind = $mod, D, exec, rofi -show drun
      bind = $mod, Q, killactive,
      bind = $mod, M, exit,
      bind = $mod, F, togglefloating,
      bind = $mod, L, exec, hyprlock
      bind = $mod, left, movefocus, l
      bind = $mod, right, movefocus, r
      bind = $mod, up, movefocus, u
      bind = $mod, down, movefocus, d

      # Switch workspaces (1 to 10)
      bind = $mod, 1, workspace, 1
      bind = $mod, 2, workspace, 2
      bind = $mod, 3, workspace, 3
      bind = $mod, 4, workspace, 4
      bind = $mod, 5, workspace, 5
      bind = $mod, 6, workspace, 6
      bind = $mod, 7, workspace, 7
      bind = $mod, 8, workspace, 8
      bind = $mod, 9, workspace, 9
      bind = $mod, 0, workspace, 10

      # Move active window to a workspace (1 to 10)
      bind = $mod SHIFT, 1, movetoworkspace, 1
      bind = $mod SHIFT, 2, movetoworkspace, 2
      bind = $mod SHIFT, 3, movetoworkspace, 3
      bind = $mod SHIFT, 4, movetoworkspace, 4
      bind = $mod SHIFT, 5, movetoworkspace, 5
      bind = $mod SHIFT, 6, movetoworkspace, 6
      bind = $mod SHIFT, 7, movetoworkspace, 7
      bind = $mod SHIFT, 8, movetoworkspace, 8
      bind = $mod SHIFT, 9, movetoworkspace, 9
      bind = $mod SHIFT, 0, movetoworkspace, 10

      # Switch workspaces using mouse side buttons
      bind = $mod, mouse:275, workspace, r-1
      bind = $mod, mouse:276, workspace, r+1

      # Move active window using mouse side buttons
      bind = $mod SHIFT, mouse:275, movetoworkspace, r-1
      bind = $mod SHIFT, mouse:276, movetoworkspace, r+1

      # Clipboard & Screenshots
      bind = $mod, V, exec, cliphist list | rofi -dmenu | cliphist decode | wl-copy
      # Print: Region screenshot to clipboard
      bind = , Print, exec, grim -g "$(slurp)" - | wl-copy && notify-send "Screenshot" "Region copied to clipboard"
      # Shift+Print: Fullscreen screenshot to clipboard
      bind = SHIFT, Print, exec, grim - | wl-copy && notify-send "Screenshot" "Fullscreen copied to clipboard"
      # Ctrl+Print: Focused window screenshot to clipboard
      bind = CTRL, Print, exec, grim -g "$(hyprctl activewindow -j | jq -r '([.at[0],.at[1]]|join(",")) + " " + ([.size[0],.size[1]]|join("x"))')" - | wl-copy && notify-send "Screenshot" "Focused window copied to clipboard"

      # Style Refresh
      bind = $mod SHIFT, W, exec, ~/.config/hypr/scripts/change_wallpaper.sh

      # Hardware Media Keys
      bindl = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
      bindl = , XF86AudioPlay, exec, playerctl play-pause
      bindl = , XF86AudioNext, exec, playerctl next
      bindl = , XF86AudioPrev, exec, playerctl previous

      bindle = , XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
      bindle = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-

      # Brightness keys (SUPER + ALT + Page_Up/Page_Down)
      bindle = $mod ALT, Page_Up, exec, ${pkgs.ddcutil}/bin/ddcutil setvcp 10 + 5
      bindle = $mod ALT, Page_Down, exec, ${pkgs.ddcutil}/bin/ddcutil setvcp 10 - 5

      # Swap window positions in tiling mode (arrows & Vim keys)
      bind = $mod SHIFT, left, swapwindow, l
      bind = $mod SHIFT, right, swapwindow, r
      bind = $mod SHIFT, up, swapwindow, u
      bind = $mod SHIFT, down, swapwindow, d
      bind = $mod SHIFT, H, swapwindow, l
      bind = $mod SHIFT, L, swapwindow, r
      bind = $mod SHIFT, K, swapwindow, u
      bind = $mod SHIFT, J, swapwindow, d

      # Resize active window (holding down keys repeats action)
      binde = $mod ALT, left, resizeactive, -30 0
      binde = $mod ALT, right, resizeactive, 30 0
      binde = $mod ALT, up, resizeactive, 0 -30
      binde = $mod ALT, down, resizeactive, 0 30

      # Move active floating window around pixel-by-pixel
      binde = $mod CTRL, left, moveactive, -30 0
      binde = $mod CTRL, right, moveactive, 30 0
      binde = $mod CTRL, up, moveactive, 0 -30
      binde = $mod CTRL, down, moveactive, 0 30

      # Mouse binds
      bindm = $mod, mouse:272, movewindow
      bindm = $mod, mouse:273, resizewindow

      # Split/Resize submap (SUPER + R to trigger)
      bind = $mod, R, submap, split
      submap = split

      # Width ratios (vertical splits)
      bind = , 1, exec, bash /home/justkowal/.config/hypr/scripts/resize_split.sh width 25
      bind = , 2, exec, bash /home/justkowal/.config/hypr/scripts/resize_split.sh width 33
      bind = , 3, exec, bash /home/justkowal/.config/hypr/scripts/resize_split.sh width 50
      bind = , 4, exec, bash /home/justkowal/.config/hypr/scripts/resize_split.sh width 66
      bind = , 5, exec, bash /home/justkowal/.config/hypr/scripts/resize_split.sh width 75
      bind = , 6, fullscreen, 1

      # Height ratios (horizontal splits)
      bind = , H, exec, bash /home/justkowal/.config/hypr/scripts/resize_split.sh height 50
      bind = , F, fullscreen, 1

      # Exit submap
      bind = , escape, submap, reset
      bind = , return, submap, reset
      bind = $mod, R, submap, reset
      submap = reset

      # Window rules for pwvucontrol
      windowrule = float 1, match:class ^(pwvucontrol|com\.saivert\.pwvucontrol)$
      windowrule = size 700 500, match:class ^(pwvucontrol|com\.saivert\.pwvucontrol)$
      windowrule = center 1, match:class ^(pwvucontrol|com\.saivert\.pwvucontrol)$

      # Window rules for gnome-calendar
      windowrule = float 1, match:class ^(org\.gnome\.Calendar)$
      windowrule = size 850 600, match:class ^(org\.gnome\.Calendar)$
      windowrule = center 1, match:class ^(org\.gnome\.Calendar)$

      # Window rules for network_tui
      windowrule = float 1, match:class ^(network_tui)$
      windowrule = size 700 500, match:class ^(network_tui)$
      windowrule = center 1, match:class ^(network_tui)$

      # Window rules for scratchpad
      windowrule = float 1, match:class ^(scratchpad)$
      windowrule = size 2176 1008, match:class ^(scratchpad)$
      windowrule = center 1, match:class ^(scratchpad)$

      # Window rules for Steam games to bypass shadows, blur, and animations
      windowrule = noanim 1, match:class ^(steam_app_.*)$
      windowrule = noshadow 1, match:class ^(steam_app_.*)$
      windowrule = noblur 1, match:class ^(steam_app_.*)$
    '';
  };

  # 5. Hyprlock (Wayland-native modern screen locker)
  programs.hyprlock = {
    enable = true;
    settings = {
      general = {
        disable_loading_bar = true;
        grace = 15; # 15-second grace period before full lock
        hide_cursor = true;
      };
      background = [
        {
          path = "screenshot"; # Blur the actual current screen state
          blur_passes = 3;
          blur_size = 8;
        }
      ];
      input-field = [
        {
          size = "250, 60";
          outline_thickness = 2;
          dots_size = 0.2;
          dots_spacing = 0.2;
          fade_on_empty = false;
          outer_color = "rgba(203, 166, 247, 1.0)"; # Mauve outline
          inner_color = "rgba(30, 30, 46, 0.9)"; # Dark background
          font_color = "rgba(205, 214, 244, 1.0)"; # Text color
          placeholder_text = "<i>Password...</i>";
        }
      ];
    };
  };

  # 6. Hypridle (Idle management daemon)
  services.hypridle = {
    enable = true;
    settings = {
      listener = [
        {
          timeout = 300; # Lock screen after 5 minutes
          on-timeout = "hyprlock";
        }
        {
          timeout = 600; # Turn off screens after 10 minutes
          on-timeout = "hyprctl dispatch dpms off";
          on-resume = "hyprctl dispatch dpms on";
        }
      ];
    };
  };

  # 7. Clipboard persistence daemon (cliphist)
  services.cliphist = {
    enable = true;
    allowImages = true;
  };

  # 8. Declarative Pointer Cursor theme
  home.pointerCursor = {
    enable = true;
    name = "Vanilla-DMZ";
    package = pkgs.vanilla-dmz;
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
    };
  };

  # 9. Declarative GTK & Qt application themes (Adwaita Dark + Matugen)
  gtk = {
    enable = true;
    colorScheme = "dark";
    theme = {
      name = "Adwaita";
    };
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
    gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = 1;
    };
    gtk4.extraConfig = {
      gtk-application-prefer-dark-theme = 1;
    };
  };

  # Ensure Qt applications follow GTK theme styling
  qt = {
    enable = true;
    platformTheme.name = "gtk3";
  };

  # 10. Firefox palette integration driven by matugen-generated colors
  programs.firefox = {
    enable = true;
    package = pkgs.firefox;
  };

  # Declaratively populate files inside active Firefox default profile without profile reset
  home.file.".mozilla/firefox/1arj8uom.default/user.js".text = ''
    user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
    user_pref("svg.context-properties.content.enabled", true);
    user_pref("userChrome.theme-material", true);
    user_pref("browser.in-content.dark-mode", true);
    user_pref("layout.css.prefers-color-scheme.content-override", 0);
    user_pref("ui.systemUsesDarkTheme", 1);
  '';

  home.file.".mozilla/firefox/1arj8uom.default/chrome/userChrome.css".text = ''
    @import "user-chrome.css";
    @import "theme-material-blue.css";
    @import "custom.css";
  '';

  home.file.".mozilla/firefox/1arj8uom.default/chrome/userContent.css".text = ''
    @import "user-content.css";
    @import "theme-material-blue.css";
    @import "custom.css";
  '';

  xdg.configFile."hypr/scripts/resize_split.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      JQ="${pkgs.jq}/bin/jq"
      HYPRCTL="${pkgs.hyprland}/bin/hyprctl"
      CUT="${pkgs.coreutils}/bin/cut"
      HEAD="${pkgs.coreutils}/bin/head"

      direction="$1"
      target_percent="$2"

      active_win=$("$HYPRCTL" activewindow -j)
      if [ -z "$active_win" ] || [ "$active_win" = "null" ]; then
        exit 0
      fi

      active_addr=$(echo "$active_win" | "$JQ" -r '.address')
      active_workspace=$(echo "$active_win" | "$JQ" -r '.workspace.id')
      x_active=$(echo "$active_win" | "$JQ" -r '.at[0]')
      y_active=$(echo "$active_win" | "$JQ" -r '.at[1]')
      w_active=$(echo "$active_win" | "$JQ" -r '.size[0]')
      h_active=$(echo "$active_win" | "$JQ" -r '.size[1]')

      monitor_id=$(echo "$active_win" | "$JQ" -r '.monitor')
      monitor_info=$("$HYPRCTL" monitors -j | "$JQ" -r ".[] | select(.id == $monitor_id)")
      monitor_width=$(echo "$monitor_info" | "$JQ" -r '.width')
      monitor_height=$(echo "$monitor_info" | "$JQ" -r '.height')

      sibling_coords=$("$HYPRCTL" clients -j | "$JQ" -r ".[] | select(.workspace.id == $active_workspace and .address != \"$active_addr\") | \"\(.address) \(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])\"" | "$HEAD" -n 1)
      if [ -z "$sibling_coords" ]; then
        exit 0
      fi

      addr_sibling=$(echo "$sibling_coords" | "$CUT" -d' ' -f1)
      x_sibling=$(echo "$sibling_coords" | "$CUT" -d' ' -f2)
      y_sibling=$(echo "$sibling_coords" | "$CUT" -d' ' -f3)
      w_sibling=$(echo "$sibling_coords" | "$CUT" -d' ' -f4)
      h_sibling=$(echo "$sibling_coords" | "$CUT" -d' ' -f5)

      # Identify left/right and top/bottom addresses and sizes
      if [ "$x_active" -lt "$x_sibling" ]; then
        addr_left="$active_addr"
        w_left="$w_active"
      else
        addr_left="$addr_sibling"
        w_left="$w_sibling"
      fi

      if [ "$y_active" -lt "$y_sibling" ]; then
        addr_top="$active_addr"
        h_top="$h_active"
      else
        addr_top="$addr_sibling"
        h_top="$h_sibling"
      fi

      if [ "$direction" = "width" ]; then
        target_width=$(( monitor_width * target_percent / 100 ))
        dw=$(( target_width - w_left ))
        
        "$HYPRCTL" dispatch focuswindow "address:$addr_left"
        "$HYPRCTL" dispatch resizeactive "$dw" 0
        "$HYPRCTL" dispatch focuswindow "address:$active_addr"
      elif [ "$direction" = "height" ]; then
        target_height=$(( monitor_height * target_percent / 100 ))
        dh=$(( target_height - h_top ))
        
        "$HYPRCTL" dispatch focuswindow "address:$addr_top"
        "$HYPRCTL" dispatch resizeactive 0 "$dh"
        "$HYPRCTL" dispatch focuswindow "address:$active_addr"
      fi
    '';
  };

  xdg.configFile."hypr/scripts/power_menu.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      options="Shutdown\nReboot\nSuspend\nLock\nExit"
      selected=$(echo -e "$options" | rofi -dmenu -i -p "Power Menu")
      case "$selected" in
        "Shutdown") systemctl poweroff ;;
        "Reboot") systemctl reboot ;;
        "Suspend") systemctl suspend ;;
        "Lock") hyprlock ;;
        "Exit") hyprctl dispatch exit ;;
      esac
    '';
  };

  xdg.configFile."hypr/scripts/sys_info.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Unified System Sensor monitor for Waybar

      # 1. Calculate CPU usage over 0.5 seconds
      read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
      prev_idle=$((idle + iowait))
      prev_non_idle=$((user + nice + system + irq + softirq + steal))
      prev_total=$((prev_idle + prev_non_idle))

      sleep 0.5

      read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
      idle=$((idle + iowait))
      non_idle=$((user + nice + system + irq + softirq + steal))
      total=$((idle + non_idle))

      total_diff=$((total - prev_total))
      idle_diff=$((idle - prev_idle))

      if [ "$total_diff" -ne 0 ]; then
          CPU_UTIL=$(( (total_diff - idle_diff) * 100 / total_diff ))
      else
          CPU_UTIL=0
      fi

      # 2. Resolve Sensor Paths
      GPU_BUSY_PATH="/sys/class/drm/card1/device/gpu_busy_percent"
      GPU_TEMP_FILE=$(find /sys/class/drm/card1/device/hwmon/ -name "temp1_input" 2>/dev/null | head -n 1)
      CPU_TEMP_FILE=$(find /sys/class/hwmon/ -name "temp1_input" | grep -v "amdgpu" | grep -v "nvme" | head -n 1)

      CPU_TEMP_DIR=$(grep -l "k10temp" /sys/class/hwmon/hwmon*/name 2>/dev/null | awk -F/ '{print "/sys/class/hwmon/" $5 "/temp1_input"}')
      if [ -f "$CPU_TEMP_DIR" ]; then
          CPU_TEMP_FILE="$CPU_TEMP_DIR"
      fi

      CPU_TEMP=0
      if [ -f "$CPU_TEMP_FILE" ]; then
          CPU_TEMP=$(( $(cat "$CPU_TEMP_FILE") / 1000 ))
      fi

      GPU_UTIL=0
      if [ -f "$GPU_BUSY_PATH" ]; then
          GPU_UTIL=$(cat "$GPU_BUSY_PATH")
      fi

      GPU_TEMP=0
      if [ -f "$GPU_TEMP_FILE" ]; then
          GPU_TEMP=$(( $(cat "$GPU_TEMP_FILE") / 1000 ))
      fi

      TEXT=" ''${CPU_UTIL}% (''${CPU_TEMP}°C)  󰾲 ''${GPU_UTIL}% (''${GPU_TEMP}°C)"
      TOOLTIP="System Status:\n\nCPU Usage: ''${CPU_UTIL}%\nCPU Temp: ''${CPU_TEMP}°C\n\nGPU Usage: ''${GPU_UTIL}%\nGPU Temp: ''${GPU_TEMP}°C"

      echo "{\"text\": \"$TEXT\", \"tooltip\": \"$TOOLTIP\"}"
    '';
  };

  xdg.configFile."waybar/scripts/pomodoro.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      STATE_FILE="''${XDG_RUNTIME_DIR:-/tmp}/waybar-pomodoro"

      init_state() {
        cat <<EOF > "$STATE_FILE"
      status=idle
      type=work
      target_time=0
      remaining_time=1500
      cycles=0
      EOF
      }

      load_state() {
        if [ ! -f "$STATE_FILE" ]; then
          init_state
        fi
        status=$(grep "^status=" "$STATE_FILE" | cut -d= -f2)
        type=$(grep "^type=" "$STATE_FILE" | cut -d= -f2)
        target_time=$(grep "^target_time=" "$STATE_FILE" | cut -d= -f2)
        remaining_time=$(grep "^remaining_time=" "$STATE_FILE" | cut -d= -f2)
        cycles=$(grep "^cycles=" "$STATE_FILE" | cut -d= -f2)

        status=''${status:-idle}
        type=''${type:-work}
        target_time=''${target_time:-0}
        remaining_time=''${remaining_time:-1500}
        cycles=''${cycles:-0}
      }

      save_state() {
        cat <<EOF > "$STATE_FILE"
      status=$status
      type=$type
      target_time=$target_time
      remaining_time=$remaining_time
      cycles=$cycles
      EOF
      }

      toggle() {
        load_state
        current_time=$(date +%s)
        if [ "$status" = "idle" ]; then
          status="running"
          if [ "$type" = "work" ]; then
            remaining_time=1500
          else
            if [ $((cycles % 4)) -eq 0 ] && [ "$cycles" -ne 0 ]; then
              remaining_time=900
            else
              remaining_time=300
            fi
          fi
          target_time=$((current_time + remaining_time))
        elif [ "$status" = "running" ]; then
          status="paused"
          remaining_time=$((target_time - current_time))
          if [ "$remaining_time" -lt 0 ]; then
            remaining_time=0
          fi
          target_time=0
        elif [ "$status" = "paused" ]; then
          status="running"
          target_time=$((current_time + remaining_time))
        fi
        save_state
      }

      reset() {
        init_state
      }

      skip() {
        load_state
        if [ "$type" = "work" ]; then
          type="break"
          cycles=$((cycles + 1))
          if [ $((cycles % 4)) -eq 0 ]; then
            remaining_time=900
          else
            remaining_time=300
          fi
        else
          type="work"
          remaining_time=1500
        fi
        status="paused"
        target_time=0
        save_state
      }

      status() {
        load_state
        current_time=$(date +%s)

        if [ "$status" = "running" ]; then
          remaining=$((target_time - current_time))
          if [ "$remaining" -le 0 ]; then
            if [ "$type" = "work" ]; then
              cycles=$((cycles + 1))
              type="break"
              if [ $((cycles % 4)) -eq 0 ]; then
                remaining_time=900
                msg="Time for a long break (15 mins)!"
              else
                remaining_time=300
                msg="Time for a short break (5 mins)!"
              fi
              notify-send -u critical -i timer-symbolic "Pomodoro Timer" "Work session finished! $msg"
            else
              type="work"
              remaining_time=1500
              notify-send -u critical -i timer-symbolic "Pomodoro Timer" "Break finished! Back to work."
            fi
            status="paused"
            target_time=0
            save_state
            remaining=$remaining_time
          fi
        else
          remaining=$remaining_time
        fi

        min=$((remaining / 60))
        sec=$((remaining % 60))
        time_str=$(printf "%02d:%02d" $min $sec)

        if [ "$status" = "idle" ]; then
          icon="󱎫"
          text=""
          tooltip="Click to start Work session (25m)"
          class="idle"
        elif [ "$status" = "paused" ]; then
          if [ "$type" = "work" ]; then
            icon="🍅"
            text="$time_str (Paused)"
            tooltip="Paused Work session. Click to resume."
            class="paused"
          else
            icon=""
            text="$time_str (Paused)"
            tooltip="Paused Break session. Click to resume."
            class="paused"
          fi
        elif [ "$status" = "running" ]; then
          if [ "$type" = "work" ]; then
            icon="🍅"
            text="$time_str"
            tooltip="Working... Click to pause."
            class="work"
          else
            icon=""
            text="$time_str"
            tooltip="On break... Click to pause."
            class="break"
          fi
        fi

        if [ -n "$text" ]; then
          display_text="$icon $text"
        else
          display_text="$icon"
        fi

        printf '{"text": "%s", "tooltip": "%s\\nCycle: %s", "class": "%s"}\n' "$display_text" "$tooltip" "$cycles" "$class"
      }

      case "$1" in
        toggle) toggle ;;
        reset) reset ;;
        skip) skip ;;
        status|*) status ;;
      esac
    '';
  };

  xdg.configFile."macchina/macchina.toml".text = ''
    theme = "nixos"
  '';

  xdg.configFile."macchina/themes/nixos.toml".text = ''
    # NixOS theme for macchina
    spacing = 2
    padding = 0
    hide_ascii = false
    prefer_small_ascii = false

    [custom_ascii]
    path = "/home/justkowal/.config/macchina/nixos_logo.txt"
    color = "Cyan"
  '';

  xdg.configFile."macchina/nixos_logo.txt".text = ''
              ▗▄▄▄       ▗▄▄▄▄    ▄▄▄▖
              ▜███▙       ▜███▙  ▟███▛
               ▜███▙       ▜███▙▟███▛
                ▜███▙       ▜██████▛
         ▟█████████████████▙ ▜████▛     ▟▙
        ▟███████████████████▙ ▜███▙    ▟██▙
               ▄▄▄▄▖           ▜███▙  ▟███▛
              ▟███▛             ▜██▛ ▟███▛
             ▟███▛               ▜▛ ▟███▛
    ▟███████████▛                  ▟██████████▙
    ▜██████████▛                  ▟███████████▛
          ▟███▛ ▟▙               ▟███▛
         ▟███▛ ▟██▙             ▟███▛
        ▟███▛  ▜███▙           ▝▀▀▀▀
        ▜██▛    ▜███▙ ▜██████████████████▛
         ▜▛     ▟████▙ ▜████████████████▛
               ▟██████▙         ▜███▙
              ▟███▛▜███▙         ▜███▙
             ▟███▛  ▜███▙         ▜███▙
             ▝▀▀▀    ▀▀▀▀▘         ▀▀▀▘
  '';

  xdg.configFile."matugen/templates/starship.toml".text = ''
    "$schema" = 'https://starship.rs/config-schema.json'

    format = """
    []({{ colors.primary.default.hex }})\
    $os\
    $username\
    [](bg:{{ colors.secondary.default.hex }} fg:{{ colors.primary.default.hex }})\
    $directory\
    [](bg:{{ colors.tertiary.default.hex }} fg:{{ colors.secondary.default.hex }})\
    $git_branch\
    $git_status\
    [](bg:{{ colors.primary_container.default.hex }} fg:{{ colors.tertiary.default.hex }})\
    $c\
    $rust\
    $golang\
    $nodejs\
    $bun\
    $php\
    $java\
    $kotlin\
    $haskell\
    $python\
    [](bg:{{ colors.secondary_container.default.hex }} fg:{{ colors.primary_container.default.hex }})\
    $conda\
    [](bg:{{ colors.tertiary_container.default.hex }} fg:{{ colors.secondary_container.default.hex }})\
    $time\
    [ ](fg:{{ colors.tertiary_container.default.hex }})\
    $cmd_duration\
    $line_break\
    $character"""

    [os]
    disabled = false
    style = "bg:{{ colors.primary.default.hex }} fg:{{ colors.on_primary.default.hex }}"

    [os.symbols]
    NixOS = " "
    Windows = " "
    Ubuntu = "󰕈 "
    SUSE = " "
    Raspbian = "󰐿 "
    Mint = "󰣭 "
    Macos = "󰀵 "
    Manjaro = " "
    Linux = "󰌽 "
    Gentoo = "󰣨 "
    Fedora = "󰣛 "
    Alpine = " "
    Amazon = " "
    Android = " "
    AOSC = " "
    Arch = "󰣇 "
    Artix = "󰣇 "
    CentOS = " "
    Debian = "󰣚 "
    Redhat = "󱄛 "
    RedHatEnterprise = "󱄛 "

    [username]
    show_always = true
    style_user = "bg:{{ colors.primary.default.hex }} fg:{{ colors.on_primary.default.hex }}"
    style_root = "bg:{{ colors.primary.default.hex }} fg:{{ colors.on_primary.default.hex }}"
    format = '[ $user]($style)'

    [directory]
    style = "bg:{{ colors.secondary.default.hex }} fg:{{ colors.on_secondary.default.hex }}"
    format = "[ $path ]($style)"
    truncation_length = 3
    truncation_symbol = "…/"

    [directory.substitutions]
    "Documents" = "󰈙 "
    "Downloads" = " "
    "Music" = "󰝚 "
    "Pictures" = " "
    "Developer" = "󰲋 "

    [git_branch]
    symbol = ""
    style = "bg:{{ colors.tertiary.default.hex }} fg:{{ colors.on_tertiary.default.hex }}"
    format = '[[ $symbol $branch ](fg:{{ colors.on_tertiary.default.hex }} bg:{{ colors.tertiary.default.hex }})]($style)'

    [git_status]
    style = "bg:{{ colors.tertiary.default.hex }} fg:{{ colors.on_tertiary.default.hex }}"
    format = '[[($all_status$ahead_behind )](fg:{{ colors.on_tertiary.default.hex }} bg:{{ colors.tertiary.default.hex }})]($style)'

    [nodejs]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [bun]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [c]
    symbol = " "
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [rust]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [golang]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [php]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [java]
    symbol = " "
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [kotlin]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [haskell]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [python]
    symbol = ""
    style = "bg:{{ colors.primary_container.default.hex }} fg:{{ colors.on_primary_container.default.hex }}"
    format = '[[ $symbol( $version)(\\(#$virtualenv\\)) ](fg:{{ colors.on_primary_container.default.hex }} bg:{{ colors.primary_container.default.hex }})]($style)'

    [docker_context]
    symbol = ""
    style = "bg:{{ colors.secondary_container.default.hex }} fg:{{ colors.on_secondary_container.default.hex }}"
    format = '[[ $symbol( $context) ](fg:{{ colors.on_secondary_container.default.hex }} bg:{{ colors.secondary_container.default.hex }})]($style)'

    [conda]
    symbol = "  "
    style = "bg:{{ colors.secondary_container.default.hex }} fg:{{ colors.on_secondary_container.default.hex }}"
    format = '[$symbol$environment ]($style)'
    ignore_base = false

    [time]
    disabled = false
    time_format = "%R"
    style = "bg:{{ colors.tertiary_container.default.hex }} fg:{{ colors.on_tertiary_container.default.hex }}"
    format = '[[  $time ](fg:{{ colors.on_tertiary_container.default.hex }} bg:{{ colors.tertiary_container.default.hex }})]($style)'

    [line_break]
    disabled = true

    [character]
    disabled = false
    success_symbol = '[❯](bold fg:{{ colors.primary.default.hex }})'
    error_symbol = '[❯](bold fg:{{ colors.error.default.hex }})'
    vimcmd_symbol = '[❮](bold fg:{{ colors.primary.default.hex }})'
    vimcmd_replace_one_symbol = '[❮](bold fg:{{ colors.tertiary_container.default.hex }})'
    vimcmd_replace_symbol = '[❮](bold fg:{{ colors.tertiary_container.default.hex }})'
    vimcmd_visual_symbol = '[❮](bold fg:{{ colors.secondary.default.hex }})'

    [cmd_duration]
    show_milliseconds = true
    format = " in $duration "
    style = "fg:{{ colors.on_background.default.hex }}"
    disabled = false
    show_notifications = true
    min_time_to_notify = 45000
  '';

  xdg.configFile."matugen/templates/vscode-theme.json".text = ''
    {
      "name": "Matugen",
      "type": "dark",
      "colors": {
        "activityBar.background": "{{ colors.surface.default.hex }}",
        "activityBar.foreground": "{{ colors.on_surface.default.hex }}",
        "activityBarBadge.background": "{{ colors.primary.default.hex }}",
        "activityBarBadge.foreground": "{{ colors.on_primary.default.hex }}",
        "editor.background": "{{ colors.background.default.hex }}",
        "editor.foreground": "{{ colors.on_background.default.hex }}",
        "editor.selectionBackground": "{{ colors.primary.default.hex }}",
        "editor.inactiveSelectionBackground": "{{ colors.surface_variant.default.hex }}",
        "editor.lineHighlightBackground": "{{ colors.surface_variant.default.hex }}",
        "editorCursor.foreground": "{{ colors.primary.default.hex }}",
        "editorIndentGuide.background1": "{{ colors.outline.default.hex }}",
        "editorIndentGuide.activeBackground1": "{{ colors.primary.default.hex }}",
        "editorLineNumber.foreground": "{{ colors.on_surface_variant.default.hex }}",
        "editorLineNumber.activeForeground": "{{ colors.on_background.default.hex }}",
        "editorWidget.background": "{{ colors.surface.default.hex }}",
        "editorWidget.foreground": "{{ colors.on_surface.default.hex }}",
        "focusBorder": "{{ colors.primary.default.hex }}",
        "input.background": "{{ colors.surface.default.hex }}",
        "input.foreground": "{{ colors.on_surface.default.hex }}",
        "input.border": "{{ colors.outline.default.hex }}",
        "list.activeSelectionBackground": "{{ colors.primary.default.hex }}",
        "list.activeSelectionForeground": "{{ colors.on_primary.default.hex }}",
        "list.hoverBackground": "{{ colors.surface_variant.default.hex }}",
        "list.inactiveSelectionBackground": "{{ colors.surface_variant.default.hex }}",
        "menu.background": "{{ colors.surface.default.hex }}",
        "menu.foreground": "{{ colors.on_surface.default.hex }}",
        "panel.background": "{{ colors.surface.default.hex }}",
        "panel.border": "{{ colors.outline.default.hex }}",
        "peekView.border": "{{ colors.primary.default.hex }}",
        "peekViewEditor.background": "{{ colors.background.default.hex }}",
        "peekViewResult.background": "{{ colors.surface.default.hex }}",
        "statusBar.background": "{{ colors.background.default.hex }}",
        "statusBar.foreground": "{{ colors.on_background.default.hex }}",
        "statusBar.debuggingBackground": "{{ colors.tertiary.default.hex }}",
        "sideBar.background": "{{ colors.background.default.hex }}",
        "sideBar.foreground": "{{ colors.on_background.default.hex }}",
        "sideBarSectionHeader.background": "{{ colors.surface.default.hex }}",
        "sideBarSectionHeader.foreground": "{{ colors.on_surface.default.hex }}",
        "tab.activeBackground": "{{ colors.surface.default.hex }}",
        "tab.activeForeground": "{{ colors.on_surface.default.hex }}",
        "tab.border": "{{ colors.outline.default.hex }}",
        "tab.inactiveBackground": "{{ colors.background.default.hex }}",
        "terminal.background": "{{ colors.background.default.hex }}",
        "terminal.foreground": "{{ colors.on_background.default.hex }}",
        "terminalCursor.foreground": "{{ colors.primary.default.hex }}",
        "titleBar.activeBackground": "{{ colors.background.default.hex }}",
        "titleBar.activeForeground": "{{ colors.on_background.default.hex }}",
        "titleBar.border": "{{ colors.outline.default.hex }}",
        "window.activeBorder": "{{ colors.primary.default.hex }}",
        "window.inactiveBorder": "{{ colors.outline.default.hex }}"
      },
      "tokenColors": [
        {
          "scope": ["comment", "punctuation.definition.comment"],
          "settings": {
            "foreground": "{{ colors.on_surface_variant.default.hex }}"
          }
        },
        {
          "scope": ["string", "constant.other.symbol"],
          "settings": {
            "foreground": "{{ colors.secondary.default.hex }}"
          }
        },
        {
          "scope": ["constant.numeric", "constant.language"],
          "settings": {
            "foreground": "{{ colors.tertiary.default.hex }}"
          }
        },
        {
          "scope": ["keyword", "storage"],
          "settings": {
            "foreground": "{{ colors.primary.default.hex }}"
          }
        },
        {
          "scope": ["entity.name.function", "support.function"],
          "settings": {
            "foreground": "{{ colors.primary_container.default.hex }}"
          }
        }
      ]
    }
  '';

  # 11. Git Credentials Configuration
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "justkowal";
        email = "justkowal@users.noreply.github.com";
      };
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };

  # GitHub CLI
  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "ssh";
    };
  };

  # Zathura PDF Viewer (wrapped with poppler PDF backend)
  programs.zathura = {
    enable = true;
    package = pkgs.zathura.override {
      plugins = [ pkgs.zathuraPkgs.zathura_pdf_poppler ];
    };
    options = {
      default-bg = "#0f0f11"; # Sleek dark background
      default-fg = "#e0e0e0";
      statusbar-bg = "#151517";
      statusbar-fg = "#e0e0e0";
      recolor = true;        # Recolors documents to dark mode by default
      recolor-keephue = true;
    };
  };

  # Yazi TUI File Manager (fully integrated with Nushell)
  programs.yazi = {
    enable = true;
    enableNushellIntegration = true;
  };

  # Declarative FreeCAD 1.1 Preference Pack wrapper to make the stylesheet selectable in Themes
  home.file.".local/share/FreeCAD/v1-1/SavedPreferencePacks/package.xml".text = ''
    <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
    <package format="1" xmlns="https://wiki.freecad.org/Package_Metadata">
      <name>Matugen</name>
      <description>Dynamic Matugen theme matching system wallpaper colors</description>
      <license>MIT</license>
      <content>
        <preferencepack>
          <name>Matugen</name>
        </preferencepack>
      </content>
    </package>
  '';

  home.file.".local/share/FreeCAD/v1-1/SavedPreferencePacks/Matugen/Matugen.cfg".text = ''
    <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
    <FCParameters>
      <Group Name="Root">
        <Group Name="BaseApp">
          <Group Name="Preferences">
            <Group Name="General">
              <FCText Name="StyleSheet">matugen.qss</FCText>
            </Group>
          </Group>
        </Group>
      </Group>
    </FCParameters>
  '';

  home.file."Pictures/wallpaper.png".source = ./wallpaper.png;

  xdg.configFile."hypr/scripts/change_wallpaper.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Wallpaper selection and Matugen re-theme script

      WALLPAPER_DIR="$HOME/Pictures/Wallpapers"
      DEFAULT_WALLPAPER="$HOME/Pictures/wallpaper.png"

      if [ -d "$WALLPAPER_DIR" ] && [ "$(ls -A "$WALLPAPER_DIR")" ]; then
          WALLPAPER=$(find "$WALLPAPER_DIR" -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.webp" \) | shuf -n 1)
      else
          PICTURES_DIR="$HOME/Pictures"
          if [ -d "$PICTURES_DIR" ]; then
              WALLPAPER=$(find "$PICTURES_DIR" -maxdepth 1 -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.webp" \) | shuf -n 1)
          fi
      fi

      if [ -z "$WALLPAPER" ] || [ ! -f "$WALLPAPER" ]; then
          WALLPAPER="$DEFAULT_WALLPAPER"
      fi

      if [ -f "$WALLPAPER" ]; then
          awww img "$WALLPAPER" --transition-type wipe
          matugen image -m dark --source-color-index 0 "$WALLPAPER"
      else
          echo "No wallpaper image found!" >&2
          exit 1
      fi
    '';
  };

  home.file.".local/bin/start-hyprland" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -e

      ${pkgs.matugen}/bin/matugen image -m dark --source-color-index 0 /home/justkowal/Pictures/wallpaper.png
      exec ${pkgs.hyprland}/bin/Hyprland
    '';
  };

  home.file.".vscode/extensions/matugen-theme/package.json".text = ''
    {
      "name": "matugen-theme",
      "displayName": "Matugen Theme",
      "description": "A generated theme driven by matugen.",
      "version": "0.0.1",
      "publisher": "local",
      "engines": {
        "vscode": "^1.90.0"
      },
      "contributes": {
        "themes": [
          {
            "label": "Matugen",
            "uiTheme": "vs-dark",
            "path": "./themes/matugen-theme.json"
          }
        ]
      }
    }
  '';

  xdg.configFile."matugen/templates/theme-material-blue.css".text = ''
    @media -moz-pref("userChrome.theme-material") {
      :root {
        --md-sys-color-primary: {{ colors.primary.default.hex }};
        --md-sys-color-surface-tint: {{ colors.surface_tint.default.hex }};
        --md-sys-color-on-primary: {{ colors.on_primary.default.hex }};
        --md-sys-color-primary-container: {{ colors.primary_container.default.hex }};
        --md-sys-color-on-primary-container: {{ colors.on_primary_container.default.hex }};
        --md-sys-color-secondary: {{ colors.secondary.default.hex }};
        --md-sys-color-on-secondary: {{ colors.on_secondary.default.hex }};
        --md-sys-color-secondary-container: {{ colors.secondary_container.default.hex }};
        --md-sys-color-on-secondary-container: {{ colors.on_secondary_container.default.hex }};
        --md-sys-color-tertiary: {{ colors.tertiary.default.hex }};
        --md-sys-color-on-tertiary: {{ colors.on_tertiary.default.hex }};
        --md-sys-color-tertiary-container: {{ colors.tertiary_container.default.hex }};
        --md-sys-color-on-tertiary-container: {{ colors.on_tertiary_container.default.hex }};
        --md-sys-color-error: {{ colors.error.default.hex }};
        --md-sys-color-on-error: {{ colors.on_error.default.hex }};
        --md-sys-color-error-container: {{ colors.error_container.default.hex }};
        --md-sys-color-on-error-container: {{ colors.on_error_container.default.hex }};
        --md-sys-color-background: {{ colors.background.default.hex }};
        --md-sys-color-on-background: {{ colors.on_background.default.hex }};
        --md-sys-color-surface: {{ colors.surface.default.hex }};
        --md-sys-color-on-surface: {{ colors.on_surface.default.hex }};
        --md-sys-color-surface-variant: {{ colors.surface_variant.default.hex }};
        --md-sys-color-on-surface-variant: {{ colors.on_surface_variant.default.hex }};
        --md-sys-color-outline: {{ colors.outline.default.hex }};
        --md-sys-color-outline-variant: {{ colors.outline_variant.default.hex }};
        --md-sys-color-shadow: {{ colors.shadow.default.hex }};
        --md-sys-color-scrim: {{ colors.scrim.default.hex }};
        --md-sys-color-inverse-surface: {{ colors.inverse_surface.default.hex }};
        --md-sys-color-inverse-on-surface: {{ colors.inverse_on_surface.default.hex }};
        --md-sys-color-inverse-primary: {{ colors.inverse_primary.default.hex }};
        --md-sys-color-primary-fixed: {{ colors.primary_fixed.default.hex }};
        --md-sys-color-on-primary-fixed: {{ colors.on_primary_fixed.default.hex }};
        --md-sys-color-primary-fixed-dim: {{ colors.primary_fixed_dim.default.hex }};
        --md-sys-color-on-primary-fixed-variant: {{ colors.on_primary_fixed_variant.default.hex }};
        --md-sys-color-secondary-fixed: {{ colors.secondary_fixed.default.hex }};
        --md-sys-color-on-secondary-fixed: {{ colors.on_secondary_fixed.default.hex }};
        --md-sys-color-secondary-fixed-dim: {{ colors.secondary_fixed_dim.default.hex }};
        --md-sys-color-on-secondary-fixed-variant: {{ colors.on_secondary_fixed_variant.default.hex }};
        --md-sys-color-tertiary-fixed: {{ colors.tertiary_fixed.default.hex }};
        --md-sys-color-on-tertiary-fixed: {{ colors.on_tertiary_fixed.default.hex }};
        --md-sys-color-tertiary-fixed-dim: {{ colors.tertiary_fixed_dim.default.hex }};
        --md-sys-color-on-tertiary-fixed-variant: {{ colors.on_tertiary_fixed_variant.default.hex }};
        --md-sys-color-surface-dim: {{ colors.surface_dim.default.hex }};
        --md-sys-color-surface-bright: {{ colors.surface_bright.default.hex }};
        --md-sys-color-surface-container-lowest: {{ colors.surface_container_lowest.default.hex }};
        --md-sys-color-surface-container-low: {{ colors.surface_container_low.default.hex }};
        --md-sys-color-surface-container: {{ colors.surface_container.default.hex }};
        --md-sys-color-surface-container-high: {{ colors.surface_container_high.default.hex }};
        --md-sys-color-surface-container-highest: {{ colors.surface_container_highest.default.hex }};
      }

      @media (prefers-color-scheme: dark) {
        :root {
          --md-sys-color-primary: {{ colors.primary.default.hex }};
          --md-sys-color-surface-tint: {{ colors.surface_tint.default.hex }};
          --md-sys-color-on-primary: {{ colors.on_primary.default.hex }};
          --md-sys-color-primary-container: {{ colors.primary_container.default.hex }};
          --md-sys-color-on-primary-container: {{ colors.on_primary_container.default.hex }};
          --md-sys-color-secondary: {{ colors.secondary.default.hex }};
          --md-sys-color-on-secondary: {{ colors.on_secondary.default.hex }};
          --md-sys-color-secondary-container: {{ colors.secondary_container.default.hex }};
          --md-sys-color-on-secondary-container: {{ colors.on_secondary_container.default.hex }};
          --md-sys-color-tertiary: {{ colors.tertiary.default.hex }};
          --md-sys-color-on-tertiary: {{ colors.on_tertiary.default.hex }};
          --md-sys-color-tertiary-container: {{ colors.tertiary_container.default.hex }};
          --md-sys-color-on-tertiary-container: {{ colors.on_tertiary_container.default.hex }};
          --md-sys-color-error: {{ colors.error.default.hex }};
          --md-sys-color-on-error: {{ colors.on_error.default.hex }};
          --md-sys-color-error-container: {{ colors.error_container.default.hex }};
          --md-sys-color-on-error-container: {{ colors.on_error_container.default.hex }};
          --md-sys-color-background: {{ colors.background.default.hex }};
          --md-sys-color-on-background: {{ colors.on_background.default.hex }};
          --md-sys-color-surface: {{ colors.surface.default.hex }};
          --md-sys-color-on-surface: {{ colors.on_surface.default.hex }};
          --md-sys-color-surface-variant: {{ colors.surface_variant.default.hex }};
          --md-sys-color-on-surface-variant: {{ colors.on_surface_variant.default.hex }};
          --md-sys-color-outline: {{ colors.outline.default.hex }};
          --md-sys-color-outline-variant: {{ colors.outline_variant.default.hex }};
          --md-sys-color-shadow: {{ colors.shadow.default.hex }};
          --md-sys-color-scrim: {{ colors.scrim.default.hex }};
          --md-sys-color-inverse-surface: {{ colors.inverse_surface.default.hex }};
          --md-sys-color-inverse-on-surface: {{ colors.inverse_on_surface.default.hex }};
          --md-sys-color-inverse-primary: {{ colors.inverse_primary.default.hex }};
          --md-sys-color-primary-fixed: {{ colors.primary_fixed.default.hex }};
          --md-sys-color-on-primary-fixed: {{ colors.on_primary_fixed.default.hex }};
          --md-sys-color-primary-fixed-dim: {{ colors.primary_fixed_dim.default.hex }};
          --md-sys-color-on-primary-fixed-variant: {{ colors.on_primary_fixed_variant.default.hex }};
          --md-sys-color-secondary-fixed: {{ colors.secondary_fixed.default.hex }};
          --md-sys-color-on-secondary-fixed: {{ colors.on_secondary_fixed.default.hex }};
          --md-sys-color-secondary-fixed-dim: {{ colors.secondary_fixed_dim.default.hex }};
          --md-sys-color-on-secondary-fixed-variant: {{ colors.on_secondary_fixed_variant.default.hex }};
          --md-sys-color-tertiary-fixed: {{ colors.tertiary_fixed.default.hex }};
          --md-sys-color-on-tertiary-fixed: {{ colors.on_tertiary_fixed.default.hex }};
          --md-sys-color-tertiary-fixed-dim: {{ colors.tertiary_fixed_dim.default.hex }};
          --md-sys-color-on-tertiary-fixed-variant: {{ colors.on_tertiary_fixed_variant.default.hex }};
          --md-sys-color-surface-dim: {{ colors.surface_dim.default.hex }};
          --md-sys-color-surface-bright: {{ colors.surface_bright.default.hex }};
          --md-sys-color-surface-container-lowest: {{ colors.surface_container_lowest.default.hex }};
          --md-sys-color-surface-container-low: {{ colors.surface_container_low.default.hex }};
          --md-sys-color-surface-container: {{ colors.surface_container.default.hex }};
          --md-sys-color-surface-container-high: {{ colors.surface_container_high.default.hex }};
          --md-sys-color-surface-container-highest: {{ colors.surface_container_highest.default.hex }};
        }
      }
    }
  '';

  xdg.configFile."matugen/templates/waybar-colors.css".text = ''
    @define-color background {{ colors.background.default.hex }};
    @define-color on_background {{ colors.on_background.default.hex }};
    @define-color surface {{ colors.surface.default.hex }};
    @define-color surface_variant {{ colors.surface_variant.default.hex }};
    @define-color on_surface {{ colors.on_surface.default.hex }};
    @define-color on_surface_variant {{ colors.on_surface_variant.default.hex }};
    @define-color primary {{ colors.primary.default.hex }};
    @define-color primary_container {{ colors.primary_container.default.hex }};
    @define-color on_primary {{ colors.on_primary.default.hex }};
    @define-color secondary {{ colors.secondary.default.hex }};
    @define-color tertiary {{ colors.tertiary.default.hex }};
    @define-color outline {{ colors.outline.default.hex }};
  '';

  xdg.configFile."matugen/templates/hyprland-colors.conf".text = ''
    $background = rgba({{ colors.background.default.hex_stripped }}ff)
    $background_transparent = rgba({{ colors.background.default.hex_stripped }}cc)
    $surface = rgba({{ colors.surface.default.hex_stripped }}ff)
    $surface_variant = rgba({{ colors.surface_variant.default.hex_stripped }}ff)
    $on_surface = rgba({{ colors.on_surface.default.hex_stripped }}ff)
    $primary = rgba({{ colors.primary.default.hex_stripped }}ff)
    $secondary = rgba({{ colors.secondary.default.hex_stripped }}ff)
    $tertiary = rgba({{ colors.tertiary.default.hex_stripped }}ff)
    $outline = rgba({{ colors.outline.default.hex_stripped }}ff)
  '';

  xdg.configFile."matugen/templates/kitty-colors.conf".text = ''
    # Matugen generated colors for Kitty
    background {{ colors.background.default.hex }}
    foreground {{ colors.on_background.default.hex }}
    cursor {{ colors.primary.default.hex }}
    cursor_text_color {{ colors.on_primary.default.hex }}
    selection_background {{ colors.primary_container.default.hex }}
    selection_foreground {{ colors.on_primary_container.default.hex }}

    # black
    color0 {{ colors.surface.default.hex }}
    color8 {{ colors.surface_variant.default.hex }}

    # red
    color1 {{ colors.error.default.hex }}
    color9 {{ colors.error.default.hex }}

    # green
    color2 {{ colors.primary.default.hex }}
    color10 {{ colors.primary.default.hex }}

    # yellow
    color3 {{ colors.secondary.default.hex }}
    color11 {{ colors.secondary.default.hex }}

    # blue
    color4 {{ colors.tertiary.default.hex }}
    color12 {{ colors.tertiary.default.hex }}

    # magenta
    color5 {{ colors.primary_container.default.hex }}
    color13 {{ colors.primary_container.default.hex }}

    # cyan
    color6 {{ colors.outline.default.hex }}
    color14 {{ colors.outline.default.hex }}

    # white
    color7 {{ colors.on_surface.default.hex }}
    color15 {{ colors.on_surface_variant.default.hex }}
  '';

  xdg.configFile."matugen/templates/rofi-colors.rasi".text = ''
    * {
        bg-col: {{ colors.background.default.hex }};
        border-col: {{ colors.outline.default.hex }};
        selected-col: {{ colors.surface_variant.default.hex }};
        text-col: {{ colors.on_background.default.hex }};
        accent-col: {{ colors.primary.default.hex }};
    }
  '';

  xdg.configFile."matugen/templates/swaync-colors.css".text = ''
    @define-color background {{ colors.background.default.hex }};
    @define-color on_background {{ colors.on_background.default.hex }};
    @define-color surface {{ colors.surface.default.hex }};
    @define-color surface_variant {{ colors.surface_variant.default.hex }};
    @define-color on_surface {{ colors.on_surface.default.hex }};
    @define-color on_surface_variant {{ colors.on_surface_variant.default.hex }};
    @define-color primary {{ colors.primary.default.hex }};
    @define-color primary_container {{ colors.primary_container.default.hex }};
    @define-color on_primary {{ colors.on_primary.default.hex }};
    @define-color secondary {{ colors.secondary.default.hex }};
    @define-color tertiary {{ colors.tertiary.default.hex }};
    @define-color outline {{ colors.outline.default.hex }};
  '';

  xdg.configFile."matugen/templates/vscode-colors".text = ''
    {{ colors.background.default.hex }}
    {{ colors.on_surface.default.hex | saturate: 70.0, hsl }}
    {{ colors.secondary.default.hex | saturate: 20.0, hsl }}
    {{ colors.tertiary.default.hex | saturate: 15.0, hsl }}
    {{ colors.primary.default.hex }}
    {{ colors.tertiary.default.hex }}
    {{ colors.secondary_container.default.hex | saturate: 20.0, hsl }}
    {{ colors.on_surface_variant.default.hex }}
    {{ colors.surface_variant.default.hex }}
    {{ colors.surface_tint.default.hex | saturate: 15.0, hsl }}
    {{ colors.secondary.default.hex | auto_lightness: 10.0 | saturate: 20.0, hsl }}
    {{ colors.tertiary.default.hex | auto_lightness: 10.0 | saturate: 15.0, hsl }}
    {{ colors.primary.default.hex | auto_lightness: 10.0 }}
    {{ colors.tertiary.default.hex | auto_lightness: 10.0 }}
    {{ colors.primary_container.default.hex | saturate: 10.0, hsl }}
    {{ colors.on_background.default.hex }}
  '';

  xdg.configFile."matugen/templates/vscode-colors.json".text = ''
    {
      "checksum": ":)",
      "wallpaper": "{{ image }}",
      "alpha": "100",
      "special": {
        "background": "{{ colors.background.default.hex }}",
        "foreground": "{{ colors.on_background.default.hex }}",
        "cursor": "{{ colors.primary.default.hex }}"
      },
      "colors": {
        "color0": "{{ colors.background.default.hex }}",
        "color1": "{{ colors.on_surface.default.hex | saturate: 70.0, hsl }}",
        "color2": "{{ colors.secondary.default.hex | saturate: 20.0, hsl }}",
        "color3": "{{ colors.tertiary.default.hex | saturate: 15.0, hsl }}",
        "color4": "{{ colors.primary.default.hex }}",
        "color5": "{{ colors.tertiary.default.hex }}",
        "color6": "{{ colors.secondary_container.default.hex | saturate: 20.0, hsl }}",
        "color7": "{{ colors.on_surface_variant.default.hex }}",
        "color8": "{{ colors.surface_variant.default.hex }}",
        "color9": "{{ colors.surface_tint.default.hex | saturate: 15.0, hsl }}",
        "color10": "{{ colors.secondary.default.hex | auto_lightness: 10.0 | saturate: 20.0, hsl }}",
        "color11": "{{ colors.tertiary.default.hex | auto_lightness: 10.0 | saturate: 15.0, hsl }}",
        "color12": "{{ colors.primary.default.hex | auto_lightness: 10.0 }}",
        "color13": "{{ colors.tertiary.default.hex | auto_lightness: 10.0 }}",
        "color14": "{{ colors.primary_container.default.hex | saturate: 10.0, hsl }}",
        "color15": "{{ colors.on_background.default.hex }}"
      }
    }
  '';

  xdg.configFile."matugen/templates/gtk3.css".text = ''
    /* GTK3/GTK4 standard colors */
    @define-color theme_bg_color {{ colors.background.default.hex }};
    @define-color theme_fg_color {{ colors.on_background.default.hex }};
    @define-color theme_base_color {{ colors.surface.default.hex }};
    @define-color theme_text_color {{ colors.on_surface.default.hex }};
    @define-color theme_selected_bg_color {{ colors.primary.default.hex }};
    @define-color theme_selected_fg_color {{ colors.on_primary.default.hex }};
    @define-color tooltip_bg_color {{ colors.surface_variant.default.hex }};
    @define-color tooltip_fg_color {{ colors.on_surface_variant.default.hex }};

    /* Libadwaita / GTK4 specific colors */
    @define-color accent_color {{ colors.primary.default.hex }};
    @define-color accent_bg_color {{ colors.primary.default.hex }};
    @define-color accent_fg_color {{ colors.on_primary.default.hex }};
    @define-color window_bg_color {{ colors.background.default.hex }};
    @define-color window_fg_color {{ colors.on_background.default.hex }};
    @define-color view_bg_color {{ colors.surface.default.hex }};
    @define-color view_fg_color {{ colors.on_surface.default.hex }};
    @define-color headerbar_bg_color {{ colors.background.default.hex }};
    @define-color headerbar_fg_color {{ colors.on_background.default.hex }};
    @define-color headerbar_border_color {{ colors.outline.default.hex }};
    @define-color card_bg_color {{ colors.surface_variant.default.hex }};
    @define-color card_fg_color {{ colors.on_surface_variant.default.hex }};
    @define-color dialog_bg_color {{ colors.background.default.hex }};
    @define-color dialog_fg_color {{ colors.on_background.default.hex }};
    @define-color popover_bg_color {{ colors.surface_variant.default.hex }};
    @define-color popover_fg_color {{ colors.on_surface_variant.default.hex }};
  '';

  xdg.configFile."matugen/templates/gtk4.css".text = ''
    /* GTK3/GTK4 standard colors */
    @define-color theme_bg_color {{ colors.background.default.hex }};
    @define-color theme_fg_color {{ colors.on_background.default.hex }};
    @define-color theme_base_color {{ colors.surface.default.hex }};
    @define-color theme_text_color {{ colors.on_surface.default.hex }};
    @define-color theme_selected_bg_color {{ colors.primary.default.hex }};
    @define-color theme_selected_fg_color {{ colors.on_primary.default.hex }};
    @define-color tooltip_bg_color {{ colors.surface_variant.default.hex }};
    @define-color tooltip_fg_color {{ colors.on_surface_variant.default.hex }};

    /* Libadwaita / GTK4 specific colors */
    @define-color accent_color {{ colors.primary.default.hex }};
    @define-color accent_bg_color {{ colors.primary.default.hex }};
    @define-color accent_fg_color {{ colors.on_primary.default.hex }};
    @define-color window_bg_color {{ colors.background.default.hex }};
    @define-color window_fg_color {{ colors.on_background.default.hex }};
    @define-color view_bg_color {{ colors.surface.default.hex }};
    @define-color view_fg_color {{ colors.on_surface.default.hex }};
    @define-color headerbar_bg_color {{ colors.background.default.hex }};
    @define-color headerbar_fg_color {{ colors.on_background.default.hex }};
    @define-color headerbar_border_color {{ colors.outline.default.hex }};
    @define-color card_bg_color {{ colors.surface_variant.default.hex }};
    @define-color card_fg_color {{ colors.on_surface_variant.default.hex }};
    @define-color dialog_bg_color {{ colors.background.default.hex }};
    @define-color dialog_fg_color {{ colors.on_background.default.hex }};
    @define-color popover_bg_color {{ colors.surface_variant.default.hex }};
    @define-color popover_fg_color {{ colors.on_surface_variant.default.hex }};
  '';

  xdg.configFile."matugen/templates/btop.theme".text = ''
    # btop Matugen dynamic colors

    theme[main_bg]=""
    theme[main_fg]="{{ colors.on_background.default.hex }}"
    theme[title]="{{ colors.primary.default.hex }}"
    theme[hi_fg]="{{ colors.secondary.default.hex }}"
    theme[selected_bg]="{{ colors.primary_container.default.hex }}"
    theme[selected_fg]="{{ colors.on_primary_container.default.hex }}"
    theme[inactive_fg]="{{ colors.outline.default.hex }}"
    theme[graph_text]="{{ colors.on_surface_variant.default.hex }}"
    theme[meter_bg]="{{ colors.surface_variant.default.hex }}"
    theme[proc_misc]="{{ colors.tertiary.default.hex }}"

    theme[cpu_box]="{{ colors.primary.default.hex }}"
    theme[mem_box]="{{ colors.secondary.default.hex }}"
    theme[net_box]="{{ colors.tertiary.default.hex }}"
    theme[proc_box]="{{ colors.outline.default.hex }}"
    theme[div_line]="{{ colors.outline_variant.default.hex }}"

    # Temperature graph
    theme[temp_start]="{{ colors.primary.default.hex }}"
    theme[temp_mid]="{{ colors.secondary.default.hex }}"
    theme[temp_end]="{{ colors.error.default.hex }}"

    # CPU graph
    theme[cpu_start]="{{ colors.primary.default.hex }}"
    theme[cpu_mid]="{{ colors.secondary.default.hex }}"
    theme[cpu_end]="{{ colors.tertiary.default.hex }}"

    # Memory/Disk meters
    theme[free_start]="{{ colors.primary.default.hex }}"
    theme[free_mid]="{{ colors.secondary.default.hex }}"
    theme[free_end]="{{ colors.tertiary.default.hex }}"
    theme[cached_start]="{{ colors.secondary.default.hex }}"
    theme[cached_mid]="{{ colors.tertiary.default.hex }}"
    theme[cached_end]="{{ colors.primary.default.hex }}"
    theme[available_start]="{{ colors.primary.default.hex }}"
    theme[available_mid]="{{ colors.secondary.default.hex }}"
    theme[available_end]="{{ colors.tertiary.default.hex }}"
    theme[used_start]="{{ colors.secondary.default.hex }}"
    theme[used_mid]="{{ colors.tertiary.default.hex }}"
    theme[used_end]="{{ colors.error.default.hex }}"

    # Network graphs
    theme[download_start]="{{ colors.primary.default.hex }}"
    theme[download_mid]="{{ colors.secondary.default.hex }}"
    theme[download_end]="{{ colors.tertiary.default.hex }}"
    theme[upload_start]="{{ colors.tertiary.default.hex }}"
    theme[upload_mid]="{{ colors.secondary.default.hex }}"
    theme[upload_end]="{{ colors.error.default.hex }}"

    # Process gradient
    theme[process_start]="{{ colors.primary.default.hex }}"
    theme[process_mid]="{{ colors.secondary.default.hex }}"
    theme[process_end]="{{ colors.tertiary.default.hex }}"
  '';

  xdg.configFile."matugen/templates/freecad.qss".text = ''
    /*
     * Matugen Premium Dynamic Theme for FreeCAD
     */

    QMainWindow, QDialog, QDockWidget, QToolBar, QMenuBar, QMenu {
        background-color: {{ colors.background.default.hex }};
        color: {{ colors.on_background.default.hex }};
    }

    QWidget {
        color: {{ colors.on_background.default.hex }};
        font-family: "Outfit", "Segoe UI", sans-serif;
    }

    QFrame {
        background-color: transparent;
        border: none;
    }

    /* Container panels, dialog pages, and scroll areas */
    QScrollArea, QScrollArea QWidget, QScrollArea::viewport,
    QStackedWidget, QStackedWidget QWidget,
    QTabWidget, QTabWidget::pane {
        background-color: {{ colors.background.default.hex }};
        border: none;
    }

    /* Prevent text styling from bleeding into 3D view and graphics */
    QGLWidget, QOpenGLWidget, Gui--View3DInventor, Gui--View3DInventorViewer {
        background-color: transparent;
    }

    /* Menu Bar */
    QMenuBar {
        background-color: {{ colors.background.default.hex }};
        color: {{ colors.on_background.default.hex }};
        border-bottom: 1px solid {{ colors.outline.default.hex }};
    }

    QMenuBar::item {
        background: transparent;
        padding: 4px 10px;
    }

    QMenuBar::item:selected {
        background-color: {{ colors.surface_variant.default.hex }};
        border-radius: 4px;
    }

    /* Menus */
    QMenu {
        background-color: {{ colors.surface.default.hex }};
        color: {{ colors.on_surface.default.hex }};
        border: 1px solid {{ colors.outline.default.hex }};
        border-radius: 6px;
        padding: 4px;
    }

    QMenu::item {
        padding: 6px 24px;
        border-radius: 4px;
    }

    QMenu::item:selected {
        background-color: {{ colors.primary.default.hex }};
        color: {{ colors.on_primary.default.hex }};
    }

    QMenu::separator {
        height: 1px;
        background-color: {{ colors.outline.default.hex }};
        margin: 6px 4px;
    }

    /* Toolbars */
    QToolBar {
        background-color: {{ colors.background.default.hex }};
        border: none;
        border-bottom: 1px solid {{ colors.outline.default.hex }};
        spacing: 4px;
        padding: 4px;
    }

    QToolButton {
        background-color: transparent;
        border: 1px solid transparent;
        border-radius: 6px;
        padding: 4px;
    }

    QToolButton:hover {
        background-color: {{ colors.surface_variant.default.hex }};
        border: 1px solid {{ colors.outline.default.hex }};
    }

    QToolButton:checked {
        background-color: {{ colors.primary_container.default.hex }};
        color: {{ colors.on_primary_container.default.hex }};
        border: 1px solid {{ colors.primary.default.hex }};
    }

    /* Dock Widgets */
    QDockWidget {
        titlebar-close-icon: none;
        titlebar-normal-icon: none;
        border: 1px solid {{ colors.outline.default.hex }};
    }

    QDockWidget::title {
        background-color: {{ colors.surface.default.hex }};
        padding: 6px;
        font-weight: bold;
        border-bottom: 1px solid {{ colors.outline.default.hex }};
    }

    /* QSint collapsible panels (TaskPanel boxes) */
    QSint--ActionGroup {
        background-color: transparent;
        border: none;
    }

    QSint--ActionGroup QFrame[class="header"] {
        background-color: {{ colors.surface_variant.default.hex }};
        border: 1px solid {{ colors.outline.default.hex }};
        border-radius: 6px;
        padding: 2px 6px;
        margin-top: 4px;
    }

    QSint--ActionGroup QFrame[class="header"]:hover {
        background-color: {{ colors.primary_container.default.hex }};
        border: 1px solid {{ colors.primary.default.hex }};
    }

    QSint--ActionGroup QFrame[class="header"] QLabel,
    QSint--ActionGroup QFrame[class="header"] QToolButton,
    QSint--ActionGroup QFrame[class="header"] QPushButton {
        color: {{ colors.on_surface_variant.default.hex }};
        background: transparent;
        font-weight: bold;
    }

    QSint--ActionGroup QFrame[class="header"]:hover QLabel,
    QSint--ActionGroup QFrame[class="header"]:hover QToolButton,
    QSint--ActionGroup QFrame[class="header"]:hover QPushButton {
        color: {{ colors.on_primary_container.default.hex }};
    }

    QSint--ActionGroup QFrame[class="content"] {
        background-color: {{ colors.surface.default.hex }};
        border: 1px solid {{ colors.outline.default.hex }};
        border-top: none;
        border-bottom-left-radius: 6px;
        border-bottom-right-radius: 6px;
        padding: 8px;
        margin-bottom: 8px;
    }

    /* Tree, List, Table Views */
    QTreeView, QListView, QTableView {
        background-color: {{ colors.surface.default.hex }};
        color: {{ colors.on_surface.default.hex }};
        alternate-background-color: {{ colors.surface_variant.default.hex }};
        border: 1px solid {{ colors.outline.default.hex }};
        border-radius: 6px;
        selection-background-color: {{ colors.primary.default.hex }};
        selection-color: {{ colors.on_primary.default.hex }};
        padding: 4px;
    }

    QTreeView::item, QListView::item, QTableView::item {
        background-color: {{ colors.surface.default.hex }};
        color: {{ colors.on_surface.default.hex }};
        padding: 4px;
        border-radius: 4px;
    }

    QTreeView::item:alternate, QListView::item:alternate, QTableView::item:alternate {
        background-color: {{ colors.surface_variant.default.hex }};
    }

    QTreeView::item:hover, QListView::item:hover, QTableView::item:hover {
        background-color: {{ colors.surface_variant.default.hex }};
    }

    QTreeView::item:selected, QListView::item:selected, QTableView::item:selected {
        background-color: {{ colors.primary.default.hex }};
        color: {{ colors.on_primary.default.hex }};
    }

    /* Header View (for Tables) */
    QHeaderView::section {
        background-color: {{ colors.surface_variant.default.hex }};
        color: {{ colors.on_surface_variant.default.hex }};
        padding: 6px;
        border: 1px solid {{ colors.outline.default.hex }};
    }

    /* Tab Widgets */
    QTabWidget::pane {
        border: 1px solid {{ colors.outline.default.hex }};
        background-color: {{ colors.surface.default.hex }};
        border-radius: 6px;
        top: -1px;
    }

    QTabBar::tab {
        background-color: {{ colors.background.default.hex }};
        color: {{ colors.on_background.default.hex }};
        padding: 6px 16px;
        border: 1px solid {{ colors.outline.default.hex }};
        border-bottom: none;
        border-top-left-radius: 6px;
        border-top-right-radius: 6px;
        margin-right: 4px;
    }

    QTabBar::tab:selected {
        background-color: {{ colors.surface.default.hex }};
        color: {{ colors.primary.default.hex }};
        border-bottom: 2px solid {{ colors.primary.default.hex }};
        font-weight: bold;
    }

    /* Buttons */
    QPushButton {
        background-color: {{ colors.surface_variant.default.hex }};
        color: {{ colors.on_surface_variant.default.hex }};
        border: 1px solid {{ colors.outline.default.hex }};
        border-radius: 6px;
        padding: 6px 16px;
    }

    QPushButton:hover {
        background-color: {{ colors.primary_container.default.hex }};
        color: {{ colors.on_primary_container.default.hex }};
        border: 1px solid {{ colors.primary.default.hex }};
    }

    QPushButton:pressed {
        background-color: {{ colors.primary.default.hex }};
        color: {{ colors.on_primary.default.hex }};
    }

    /* Input Fields */
    QLineEdit, QTextEdit, QPlainTextEdit, QComboBox, QSpinBox, QDoubleSpinBox {
        background-color: {{ colors.surface.default.hex }};
        color: {{ colors.on_surface.default.hex }};
        border: 1px solid {{ colors.outline.default.hex }};
        border-radius: 6px;
        padding: 6px;
    }

    QLineEdit:focus, QTextEdit:focus, QComboBox:focus {
        border: 1px solid {{ colors.primary.default.hex }};
    }

    /* Checkboxes & Radio Buttons */
    QCheckBox, QRadioButton {
        spacing: 8px;
    }

    QCheckBox::indicator, QRadioButton::indicator {
        width: 16px;
        height: 16px;
        border: 1px solid {{ colors.outline.default.hex }};
        border-radius: 4px;
        background-color: {{ colors.surface.default.hex }};
    }

    QCheckBox::indicator:checked, QRadioButton::indicator:checked {
        background-color: {{ colors.primary.default.hex }};
        border-color: {{ colors.primary.default.hex }};
    }

    /* Scrollbars */
    QScrollBar:vertical {
        background-color: {{ colors.background.default.hex }};
        width: 12px;
        margin: 0px;
    }

    QScrollBar::handle:vertical {
        background-color: {{ colors.outline.default.hex }};
        min-height: 20px;
        border-radius: 6px;
        margin: 2px;
    }

    QScrollBar::handle:vertical:hover {
        background-color: {{ colors.primary.default.hex }};
    }

    QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
        border: none;
        background: none;
    }

    QScrollBar:horizontal {
        background-color: {{ colors.background.default.hex }};
        height: 12px;
        margin: 0px;
    }

    QScrollBar::handle:horizontal {
        background-color: {{ colors.outline.default.hex }};
        min-width: 20px;
        border-radius: 6px;
        margin: 2px;
    }

    QScrollBar::handle:horizontal:hover {
        background-color: {{ colors.primary.default.hex }};
    }

    QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {
        border: none;
        background: none;
    }
  '';

  xdg.configFile."matugen/templates/kicad.json".text = ''
    {
      "board": {
        "anchor": "rgb(0, 0, 132)",
        "aux_items": "rgb(255, 255, 255)",
        "b_adhes": "rgb(0, 0, 132)",
        "b_crtyd": "rgb(149, 219, 223)",
        "b_fab": "rgb(141, 210, 114)",
        "b_mask": "rgba(54, 132, 109, 0.698)",
        "b_paste": "rgb(0, 194, 194)",
        "b_silks": "rgb(121, 101, 150)",
        "background": "{{ colors.background.default.rgb }}",
        "cmts_user": "rgb(65, 160, 66)",
        "copper": {
          "b": "rgba(101, 162, 229, 0.800)",
          "f": "rgba(194, 96, 101, 0.800)",
          "in1": "rgba(194, 107, 170, 0.600)",
          "in10": "rgb(132, 0, 132)",
          "in11": "rgb(132, 0, 0)",
          "in12": "rgb(132, 132, 0)",
          "in13": "rgb(194, 194, 194)",
          "in14": "rgb(0, 0, 132)",
          "in15": "rgb(0, 132, 0)",
          "in16": "rgb(132, 0, 0)",
          "in17": "rgb(194, 194, 0)",
          "in18": "rgb(194, 0, 194)",
          "in19": "rgb(194, 0, 0)",
          "in2": "rgba(127, 194, 161, 0.600)",
          "in20": "rgb(0, 132, 132)",
          "in21": "rgb(0, 132, 0)",
          "in22": "rgb(0, 0, 132)",
          "in23": "rgb(132, 132, 132)",
          "in24": "rgb(132, 0, 132)",
          "in25": "rgb(194, 194, 194)",
          "in26": "rgb(132, 0, 132)",
          "in27": "rgb(132, 0, 0)",
          "in28": "rgb(132, 132, 0)",
          "in29": "rgb(194, 194, 194)",
          "in3": "rgb(194, 0, 0)",
          "in30": "rgb(0, 0, 132)",
          "in4": "rgb(0, 132, 132)",
          "in5": "rgb(0, 132, 0)",
          "in6": "rgb(0, 0, 132)",
          "in7": "rgb(132, 132, 132)",
          "in8": "rgb(132, 0, 132)",
          "in9": "rgb(194, 194, 194)"
        },
        "cursor": "{{ colors.on_background.default.rgb }}",
        "dwgs_user": "rgb(165, 165, 165)",
        "eco1_user": "rgb(0, 132, 0)",
        "eco2_user": "rgb(255, 87, 98)",
        "edge_cuts": "rgb(200, 163, 57)",
        "f_adhes": "rgb(132, 0, 132)",
        "f_crtyd": "rgb(201, 169, 249)",
        "f_fab": "rgb(240, 216, 121)",
        "f_mask": "rgba(180, 74, 76, 0.698)",
        "f_paste": "rgb(255, 0, 255)",
        "f_silks": "rgb(129, 190, 190)",
        "footprint_text_back": "rgb(0, 0, 132)",
        "footprint_text_front": "rgb(194, 194, 194)",
        "footprint_text_invisible": "rgb(132, 132, 132)",
        "grid": "{{ colors.outline.default.rgb }}",
        "no_connect": "rgb(0, 0, 132)",
        "pad_back": "rgba(82, 127, 185, 0.698)",
        "pad_front": "rgba(194, 118, 97, 0.698)",
        "plated_hole": "rgb(194, 194, 0)",
        "ratsnest": "rgb(179, 179, 179)",
        "via_blind_buried": "rgb(132, 132, 0)",
        "via_micro": "rgb(0, 132, 132)",
        "via_through": "rgb(194, 194, 194)",
        "worksheet": "rgb(72, 0, 0)"
      },
      "fpedit": {
        "anchor": "rgb(0, 0, 132)",
        "aux_items": "rgb(255, 255, 255)",
        "b_adhes": "rgb(0, 0, 132)",
        "b_crtyd": "rgb(149, 219, 223)",
        "b_fab": "rgb(141, 210, 114)",
        "b_mask": "rgba(0, 245, 223, 0.600)",
        "b_paste": "rgb(0, 194, 194)",
        "b_silks": "rgb(121, 101, 150)",
        "background": "{{ colors.background.default.rgb }}",
        "cmts_user": "rgb(0, 0, 132)",
        "copper": {
          "b": "rgba(82, 127, 185, 0.800)",
          "f": "rgba(236, 144, 118, 0.800)",
          "in1": "rgb(194, 194, 0)",
          "in10": "rgb(132, 0, 132)",
          "in11": "rgb(132, 0, 0)",
          "in12": "rgb(132, 132, 0)",
          "in13": "rgb(194, 194, 194)",
          "in14": "rgb(0, 0, 132)",
          "in15": "rgb(0, 132, 0)",
          "in16": "rgb(132, 0, 0)",
          "in17": "rgb(194, 194, 0)",
          "in18": "rgb(194, 0, 194)",
          "in19": "rgb(194, 0, 0)",
          "in2": "rgb(194, 0, 194)",
          "in20": "rgb(0, 132, 132)",
          "in21": "rgb(0, 132, 0)",
          "in22": "rgb(0, 0, 132)",
          "in23": "rgb(132, 132, 132)",
          "in24": "rgb(132, 0, 132)",
          "in25": "rgb(194, 194, 194)",
          "in26": "rgb(132, 0, 132)",
          "in27": "rgb(132, 0, 0)",
          "in28": "rgb(132, 132, 0)",
          "in29": "rgb(194, 194, 194)",
          "in3": "rgb(194, 0, 0)",
          "in30": "rgb(0, 0, 132)",
          "in4": "rgb(0, 132, 132)",
          "in5": "rgb(0, 132, 0)",
          "in6": "rgb(0, 0, 132)",
          "in7": "rgb(132, 132, 132)",
          "in8": "rgb(132, 0, 132)",
          "in9": "rgb(194, 194, 194)"
        },
        "cursor": "{{ colors.on_background.default.rgb }}",
        "dwgs_user": "rgb(194, 194, 194)",
        "eco1_user": "rgb(0, 132, 0)",
        "eco2_user": "rgb(194, 194, 0)",
        "edge_cuts": "rgb(194, 194, 0)",
        "f_adhes": "rgb(132, 0, 132)",
        "f_crtyd": "rgb(201, 164, 249)",
        "f_fab": "rgb(240, 216, 121)",
        "f_mask": "rgba(180, 74, 76, 0.600)",
        "f_paste": "rgba(211, 67, 187, 0.600)",
        "f_silks": "rgb(102, 150, 150)",
        "footprint_text_back": "rgb(0, 0, 132)",
        "footprint_text_front": "rgb(194, 194, 194)",
        "footprint_text_invisible": "rgb(132, 132, 132)",
        "grid": "{{ colors.outline.default.rgb }}",
        "pad_back": "rgba(82, 127, 185, 0.698)",
        "pad_front": "rgba(194, 118, 97, 0.698)",
        "pad_through_hole": "rgba(200, 200, 121, 0.698)",
        "plated_hole": "rgb(194, 194, 0)",
        "worksheet": "rgb(72, 0, 0)"
      },
      "meta": {
        "filename": "matugen",
        "name": "Matugen Theme",
        "version": 0
      },
      "schematic": {
        "background": "{{ colors.background.default.rgb }}",
        "brightened": "rgb(201, 169, 249)",
        "bus": "{{ colors.secondary.default.rgb }}",
        "component_body": "{{ colors.surface_variant.default.rgb }}",
        "component_outline": "{{ colors.primary.default.rgb }}",
        "erc_error": "{{ colors.error.default.rgb }}",
        "erc_warning": "{{ colors.tertiary.default.rgb }}",
        "fields": "rgb(120, 101, 150)",
        "grid": "{{ colors.outline.default.rgb }}",
        "junction": "{{ colors.primary.default.rgb }}",
        "label_global": "rgb(196, 108, 45)",
        "label_hier": "rgb(195, 174, 114)",
        "label_local": "{{ colors.secondary.default.rgb }}",
        "net_name": "rgb(202, 202, 202)",
        "no_connect": "rgb(149, 219, 223)",
        "note": "{{ colors.secondary.default.rgb }}",
        "pin": "{{ colors.primary.default.rgb }}",
        "pin_name": "{{ colors.on_surface_variant.default.rgb }}",
        "pin_number": "{{ colors.primary.default.rgb }}",
        "reference": "{{ colors.primary.default.rgb }}",
        "sheet": "rgb(133, 111, 165)",
        "sheet_filename": "rgb(133, 111, 165)",
        "sheet_label": "rgb(196, 122, 79)",
        "sheet_name": "{{ colors.on_surface_variant.default.rgb }}",
        "value": "{{ colors.on_surface_variant.default.rgb }}",
        "wire": "{{ colors.primary.default.rgb }}"
      }
    }
  '';

  xdg.configFile."matugen/config.toml".text = ''
    [config]
    source_color_index = 0

    [templates.theme-material-blue]
    input_path = "~/.config/matugen/templates/theme-material-blue.css"
    output_path = "~/.mozilla/firefox/1arj8uom.default/chrome/theme-material-blue.css"

    [templates.waybar-colors]
    input_path = "~/.config/matugen/templates/waybar-colors.css"
    output_path = "~/.config/waybar/colors.css"
    post_hook = "pkill -SIGUSR2 waybar"

    [templates.hyprland-colors]
    input_path = "~/.config/matugen/templates/hyprland-colors.conf"
    output_path = "~/.config/hypr/matugen.conf"
    post_hook = "hyprctl reload"

    [templates.vscode-theme]
    input_path = "~/.config/matugen/templates/vscode-theme.json"
    output_path = "~/.vscode/extensions/matugen-theme/themes/matugen-theme.json"

    [templates.kitty-colors]
    input_path = "~/.config/matugen/templates/kitty-colors.conf"
    output_path = "~/.config/kitty/colors.conf"
    post_hook = "pkill -USR1 kitty"

    [templates.rofi-colors]
    input_path = "~/.config/matugen/templates/rofi-colors.rasi"
    output_path = "~/.config/rofi/colors.rasi"

    [templates.swaync-colors]
    input_path = "~/.config/matugen/templates/swaync-colors.css"
    output_path = "~/.config/swaync/colors.css"
    post_hook = "swaync-client -R; swaync-client -rs"

    [templates.vscode-raw]
    input_path = "~/.config/matugen/templates/vscode-colors"
    output_path = "~/.cache/matugen/vscode-colors"

    [templates.vscode-json]
    input_path = "~/.config/matugen/templates/vscode-colors.json"
    output_path = "~/.cache/matugen/vscode-colors.json"

    [templates.gtk3]
    input_path = "~/.config/matugen/templates/gtk3.css"
    output_path = "~/.config/gtk-3.0/gtk.css"

    [templates.gtk4]
    input_path = "~/.config/matugen/templates/gtk4.css"
    output_path = "~/.config/gtk-4.0/gtk.css"

    [templates.starship]
    input_path = "~/.config/matugen/templates/starship.toml"
    output_path = "~/.config/starship.toml"

    [templates.btop]
    input_path = "~/.config/matugen/templates/btop.theme"
    output_path = "~/.config/btop/themes/matugen.theme"

    [templates.freecad]
    input_path = "~/.config/matugen/templates/freecad.qss"
    output_path = "~/.local/share/FreeCAD/v1-1/Gui/Stylesheets/matugen.qss"

    [templates.kicad]
    input_path = "~/.config/matugen/templates/kicad.json"
    output_path = "~/.config/kicad/10.0/colors/matugen.json"
  '';

  # 12. Declarative VS Code configuration (extensions + theme)
  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
    profiles.default = {
      extensions = with pkgs.vscode-extensions; [
        bbenoist.nix
        kamadorueda.alejandra # Declarative formatter for Nix configurations
      ];
      userSettings = {
        "workbench.colorTheme" = "Matugen";
        "editor.fontSize" = 13;
        "editor.fontFamily" = "'JetBrainsMono Nerd Font', 'monospace'";
        "editor.formatOnSave" = true;
        "nix.enableLanguageServer" = true;
        "nix.serverPath" = "nixd"; # Language server for Nix IDE
      };
    };
  };

  # 13. Nushell Profile Configuration (disable banner, auto-run macchina)
  programs.nushell = {
    enable = true;
    extraConfig = ''
      # Disable Nushell welcome banner
      $env.config = ($env.config | merge { show_banner: false })
      # Welcome user with system statistics on startup
      macchina
    '';
  };

  # 14. Starship Prompt Configuration
  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
  };

  # 15. Declarative btop resource monitor with Matugen theme integration
  programs.btop = {
    enable = true;
    settings = {
      color_theme = "matugen";
      theme_background = false; # Enable transparency to match Kitty's 0.85 opacity
      truecolor = true;
    };
  };

  # SwayNC notification center setup (MD3 glassmorphic design)
  services.swaync = {
    enable = true;
    style = ''
      @import "colors.css";

      * {
        font-family: "Outfit", "JetBrainsMono Nerd Font", sans-serif;
        font-size: 13px;
      }

      .notification {
        background-color: alpha(@surface_variant, 0.85);
        border: 1px solid alpha(@outline, 0.75);
        border-radius: 12px;
        color: @on_background;
        padding: 10px;
        margin: 5px;
      }

      .notification-content {
        margin: 5px;
      }

      .notification-title {
        font-weight: bold;
        color: @primary;
      }

      .notification-body {
        color: @on_surface;
      }

      .control-center {
        background-color: alpha(@background, 0.90);
        border: 1px solid alpha(@outline, 0.75);
        border-radius: 16px;
        padding: 15px;
      }
    '';
  };

  # 14. Declarative XDG user directories (auto-creation on login)
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
  };

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  programs.mangohud = {
    enable = true;
    settings = {
      legacy_layout = 0;
      horizontal = true;
      hud_no_margin = true;
      font_size = 14;
      font_family = "JetBrainsMono Nerd Font";
      table_columns = 3;
      background_alpha = "0.5";
      round_corners = 10;
      # Performance Stats
      fps = true;
      cpu_stats = true;
      cpu_temp = true;
      gpu_stats = true;
      gpu_temp = true;
      ram = true;
      vram = true;
    };
  };

  home.file.".steam/root/compatibilitytools.d/proton-ge-custom".source = "${pkgs.proton-ge-bin}";

  home.stateVersion = "26.05";
}
