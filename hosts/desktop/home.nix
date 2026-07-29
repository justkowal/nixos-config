{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./home-theming.nix
    ./home-ai.nix
  ];

  home.username = "justkowal";
  home.homeDirectory = "/home/justkowal";
  home.enableNixpkgsReleaseCheck = false;

  # Ensure CAD/EDA directories exist for dynamic Matugen stylesheets
  home.activation = {
    createCadEdaDirs = lib.hm.dag.entryAfter ["writeBoundary"] ''
      mkdir -p /home/justkowal/.local/share/FreeCAD/v1-1/Gui/Stylesheets
      mkdir -p /home/justkowal/.config/kicad/10.0/colors
      mkdir -p /home/justkowal/.local/share/Steam/steamui/skins

      THEME_DIR="/home/justkowal/.local/share/Steam/steamui/skins/Material-Theme"
      if [ ! -d "$THEME_DIR" ]; then
        ${pkgs.git}/bin/git clone https://github.com/kuska1/Material-Theme.git "$THEME_DIR"
      fi
    '';

    copyMangoHud = lib.hm.dag.entryAfter ["linkGeneration"] ''
      if [ -L /home/justkowal/.config/MangoHud/MangoHud.conf ]; then
        TARGET_PATH=$(readlink -f /home/justkowal/.config/MangoHud/MangoHud.conf)
        if [ -n "$TARGET_PATH" ] && [ -f "$TARGET_PATH" ]; then
          rm -f /home/justkowal/.config/MangoHud/MangoHud.conf
          cp -L "$TARGET_PATH" /home/justkowal/.config/MangoHud/MangoHud.conf
          chmod 644 /home/justkowal/.config/MangoHud/MangoHud.conf
        fi
      fi
    '';
  };

  # Global developer session variables
  home.sessionVariables = {
    TZ = "Europe/Warsaw";
    RUSTC_WRAPPER = "${pkgs.sccache}/bin/sccache";
    STARSHIP_CONFIG = "/home/justkowal/.config/starship.toml";
    GTK_THEME = "Adwaita:dark";
    MANGOHUD_CONFIGFILE = "/home/justkowal/.config/MangoHud/MangoHud.conf";
    ANKI_NIGHT_MODE = "1";
  };

  # User packages
  home.packages = with pkgs; [
    awww # Animated wallpaper daemon
    wl-clipboard # Wayland clipboard utilities
    playerctl # CLI media player controller
    grim # Screen grabber
    slurp # Region selector
    libnotify # Notification sender (notify-send)
    libcanberra-gtk3 # Event sound player (canberra-gtk-play)
    glow # Terminal markdown renderer
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
      window_padding_width = 10;
      tab_bar_edge = "top";
      tab_bar_style = "powerline";
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
    systemd = {
      enable = true;
      targets = [ "graphical-session.target" ];
    };
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
        modules-right = ["mpris" "idle_inhibitor" "custom/sysinfo" "memory" "disk" "pulseaudio" "network" "custom/notification" "tray" "custom/power"];

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

      #clock, #pulseaudio, #custom-sysinfo, #memory, #mpris, #idle_inhibitor, #network, #disk, #custom-notification, #custom-power, #custom-pomodoro {
        padding: 0 16px;
        margin: 4px 2px;
        background-color: alpha(@surface_variant, 0.82);
        border-radius: 12px;
      }

      #custom-notification {
        color: @primary;
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

      #custom-sysinfo {
        color: @primary;
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
          col.active_border = $primary $tertiary 45deg
          col.inactive_border = $outline
          layout = dwindle
      }

      decoration {
          rounding = 12
          active_opacity = 1.0
          inactive_opacity = 0.92

          blur {
              enabled = true
              size = 6
              passes = 3
              new_optimizations = true
          }
          shadow {
              enabled = false
          }
      }



      animations {
          enabled = true
          bezier = md3_decel, 0.05, 0.7, 0.1, 1.0
          bezier = bouncy, 0.175, 0.885, 0.32, 1.275
          bezier = win_decel, 0.05, 0.9, 0.1, 1.05

          animation = windows, 1, 4, bouncy, popin 85%
          animation = windowsIn, 1, 4, bouncy, popin 85%
          animation = windowsOut, 1, 3, md3_decel, popin 80%
          animation = windowsMove, 1, 4, win_decel
          animation = border, 1, 6, md3_decel
          animation = fade, 1, 4, md3_decel
          animation = workspaces, 1, 5, md3_decel, slide
          animation = specialWorkspace, 1, 4, bouncy, slidevert
      }

      misc {
          vrr = 0
      }

      cursor {
          no_hardware_cursors = true
      }

      render {
          direct_scanout = true
      }

      # Autostart
      exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
      exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
      exec-once = ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --start --components=secrets,pkcs11,ssh
      exec-once = systemctl --user start waybar
      exec-once = sleep 0.5 && awww img /home/justkowal/Pictures/wallpaper.png --transition-type wipe --transition-step 90
      # nm-applet is disabled to avoid duplicate network tray/bar icons
      # exec-once = nm-applet --indicator
      exec-once = blueman-applet
      exec-once = [workspace special:term silent] kitty --class scratchpad

      # Binds
      $mod = SUPER
      bind = $mod, RETURN, exec, kitty
      bind = $mod, B, exec, firefox
      bind = $mod, ESCAPE, exec, bash ~/.config/hypr/scripts/power_menu.sh
      bind = $mod, grave, togglespecialworkspace, term
      bind = $mod, D, exec, bash ~/.config/hypr/scripts/spotlight.sh
      bind = $mod, SPACE, exec, bash ~/.config/hypr/scripts/spotlight.sh
      bind = $mod, A, exec, bash ~/.config/hypr/scripts/rofi_ai.sh
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

      # Clipboard & AI Notifications
      bind = $mod, V, exec, bash ~/.config/hypr/scripts/cliphist_picker.sh
      bind = $mod ALT, N, exec, bash ~/.config/ai/notification_digest.sh
      bind = $mod SHIFT, S, exec, bash ~/.config/hypr/scripts/ai_ocr_screenshot.sh
      # Print: Region screenshot to clipboard
      bind = , Print, exec, ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp)" - | ${pkgs.wl-clipboard}/bin/wl-copy && ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i camera-shutter 2>/dev/null && ${pkgs.libnotify}/bin/notify-send "Screenshot" "Region copied to clipboard"
      # Shift+Print: Fullscreen screenshot to clipboard
      bind = SHIFT, Print, exec, ${pkgs.grim}/bin/grim - | ${pkgs.wl-clipboard}/bin/wl-copy && ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i camera-shutter 2>/dev/null && ${pkgs.libnotify}/bin/notify-send "Screenshot" "Fullscreen copied to clipboard"
      # Ctrl+Print: Focused window screenshot to clipboard
      bind = CTRL, Print, exec, ${pkgs.grim}/bin/grim -g "$(${pkgs.hyprland}/bin/hyprctl activewindow -j | ${pkgs.jq}/bin/jq -r '([.at[0],.at[1]]|join(",")) + " " + ([.size[0],.size[1]]|join("x"))')" - | ${pkgs.wl-clipboard}/bin/wl-copy && ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i camera-shutter 2>/dev/null && ${pkgs.libnotify}/bin/notify-send "Screenshot" "Focused window copied to clipboard"

      # Style Refresh
      bind = $mod SHIFT, W, exec, ~/.config/hypr/scripts/change_wallpaper.sh

      # Hardware Media & Volume Keys with Graphical OSD
      bindl = , XF86AudioMute, exec, bash ~/.config/hypr/scripts/volume_osd.sh mute
      bindl = , XF86AudioPlay, exec, playerctl play-pause
      bindl = , XF86AudioNext, exec, playerctl next
      bindl = , XF86AudioPrev, exec, playerctl previous

      bindle = , XF86AudioRaiseVolume, exec, bash ~/.config/hypr/scripts/volume_osd.sh up
      bindle = , XF86AudioLowerVolume, exec, bash ~/.config/hypr/scripts/volume_osd.sh down

      # Brightness keys with Graphical OSD (SUPER + ALT + Page_Up/Page_Down)
      bindle = $mod ALT, Page_Up, exec, bash ~/.config/hypr/scripts/brightness_osd.sh up
      bindle = $mod ALT, Page_Down, exec, bash ~/.config/hypr/scripts/brightness_osd.sh down

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

      # TTY Switching (Virtual Terminals)
      bind = CTRL ALT, F1, exec, chvt 1
      bind = CTRL ALT, F2, exec, chvt 2
      bind = CTRL ALT, F3, exec, chvt 3
      bind = CTRL ALT, F4, exec, chvt 4
      bind = CTRL ALT, F5, exec, chvt 5
      bind = CTRL ALT, F6, exec, chvt 6
      bind = CTRL ALT, F7, exec, chvt 7
      bind = CTRL ALT, F8, exec, chvt 8
      bind = CTRL ALT, F9, exec, chvt 9
      bind = CTRL ALT, F10, exec, chvt 10
      bind = CTRL ALT, F11, exec, chvt 11
      bind = CTRL ALT, F12, exec, chvt 12

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
      windowrule = no_anim 1, match:class ^(steam_app_.*)$
      windowrule = no_shadow 1, match:class ^(steam_app_.*)$
      windowrule = no_blur 1, match:class ^(steam_app_.*)$
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
          timeout = 900; # Lock screen after 15 minutes
          on-timeout = "hyprlock";
        }
        {
          timeout = 1800; # Turn off screens after 30 minutes
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

  # 10. Firefox palette integration driven by matugen-generated colors & high performance tuning
  programs.firefox = {
    enable = true;
    package = pkgs.firefox;
    policies = {
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      DisablePocket = true;
      DisableFirefoxAccounts = false;
      OverrideFirstRunPage = "";
      OverridePostUpdatePage = "";
    };
  };

  # Declaratively populate files inside active Firefox default profile without profile reset
  home.file.".mozilla/firefox/1arj8uom.default/user.js".text = ''
    user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
    user_pref("svg.context-properties.content.enabled", true);
    user_pref("userChrome.theme-material", true);
    user_pref("browser.in-content.dark-mode", true);
    user_pref("layout.css.prefers-color-scheme.content-override", 0);
    user_pref("ui.systemUsesDarkTheme", 1);

    /* Hardware GPU WebRender Acceleration */
    user_pref("gfx.webrender.all", true);
    user_pref("gfx.webrender.compositor", true);

    /* VA-API Hardware Video Decoding on AMD GPU */
    user_pref("media.hardware-video-decoding.enabled", true);
    user_pref("media.ffmpeg.vaapi.enabled", true);

    /* 1GB High-Speed RAM Cache for instant navigation & tab switching */
    user_pref("browser.cache.memory.enable", true);
    user_pref("browser.cache.memory.capacity", 1048576);
    user_pref("browser.tabs.remote.warmup.enabled", true);

    /* Disable startup telemetry & first-run delay overlays */
    user_pref("browser.startup.homepage_override.mstone", "ignore");
    user_pref("toolkit.telemetry.enabled", false);
    user_pref("browser.newtabpage.activity-stream.telemetry", false);
    user_pref("browser.ping-centre.telemetry", false);
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

  xdg.configFile."hypr/scripts/volume_osd.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      case "$1" in
        up) ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ ;;
        down) ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
        mute) ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
      esac

      VOL=$(${pkgs.wireplumber}/bin/wpctl get-volume @DEFAULT_AUDIO_SINK@ | ${pkgs.gawk}/bin/awk '{print int($2 * 100)}')
      MUTED=$(${pkgs.wireplumber}/bin/wpctl get-volume @DEFAULT_AUDIO_SINK@ | ${pkgs.gnugrep}/bin/grep -i MUTED)

      if [ -n "$MUTED" ]; then
        ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:osd -h int:value:0 -i audio-volume-muted "Volume" "Muted (0%)"
      else
        ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:osd -h int:value:"$VOL" -i audio-volume-high "Volume" "$VOL%"
      fi
    '';
  };

  xdg.configFile."hypr/scripts/brightness_osd.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      case "$1" in
        up) ${pkgs.ddcutil}/bin/ddcutil setvcp 10 + 5 ;;
        down) ${pkgs.ddcutil}/bin/ddcutil setvcp 10 - 5 ;;
      esac

      BRIGHT=$(${pkgs.ddcutil}/bin/ddcutil getvcp 10 2>/dev/null | ${pkgs.gnugrep}/bin/grep -oP 'current value =\s*\K\d+' || echo "50")
      ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:osd -h int:value:"$BRIGHT" -i display-brightness "Monitor Brightness" "$BRIGHT%"
    '';
  };

  xdg.configFile."hypr/scripts/power_menu.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      options="🔒 Lock Screen\n💤 Suspend\n🔄 Reboot System\n⚡ Shutdown System\n🚪 Exit Hyprland Session"
      selected=$(echo -e "$options" | rofi -dmenu -i -p "Power Menu" -font "Outfit 12" -theme-str 'window {width: 450px;}')
      case "$selected" in
        *"Shutdown"*) systemctl poweroff ;;
        *"Reboot"*) systemctl reboot ;;
        *"Suspend"*) systemctl suspend ;;
        *"Lock"*) ${pkgs.hyprlock}/bin/hyprlock ;;
        *"Exit"*) ${pkgs.hyprland}/bin/hyprctl dispatch exit ;;
      esac
    '';
  };

  xdg.configFile."hypr/scripts/change_wallpaper.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      WALLPAPER="/home/justkowal/Pictures/wallpaper.png"
      WALLPAPER_DIR="/home/justkowal/Pictures/Wallpapers"

      if [ -d "$WALLPAPER_DIR" ]; then
        RANDOM_WALL=$(find "$WALLPAPER_DIR" -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.webp" \) 2>/dev/null | shuf -n 1)
        if [ -n "$RANDOM_WALL" ]; then
          WALLPAPER="$RANDOM_WALL"
        fi
      fi

      if command -v awww &>/dev/null; then
        awww img "$WALLPAPER" --transition-type wipe --transition-step 90
      fi

      if command -v matugen &>/dev/null; then
        matugen image --source-color-index 0 "$WALLPAPER"
      fi

      ${pkgs.libnotify}/bin/notify-send -i image-x-generic "Wallpaper Changed" "Applied: $(basename "$WALLPAPER")"
    '';
  };

  # IDE Continue Extension pre-configured with local Ollama ROCm backend
  home.file.".continue/config.json".text = ''
    {
      "models": [
        {
          "title": "Huihui Gemma 4 12B IT (Abliterated)",
          "provider": "ollama",
          "model": "huihui-ai/Huihui-gemma-4-12B-it-abliterated",
          "apiBase": "http://127.0.0.1:11434"
        },
        {
          "title": "Huihui Gemma 4 E4B IT (Abliterated)",
          "provider": "ollama",
          "model": "huihui-ai/Huihui-gemma-4-E4B-it-abliterated",
          "apiBase": "http://127.0.0.1:11434"
        },
        {
          "title": "Huihui Gemma 4 12B Coder (Abliterated)",
          "provider": "ollama",
          "model": "huihui-ai/Huihui-gemma-4-12B-coder-fable5-composer2.5-v1-abliterated",
          "apiBase": "http://127.0.0.1:11434"
        }
      ],
      "tabAutocompleteModel": {
        "title": "Huihui Gemma 4 E2B Autocomplete (Fast)",
        "provider": "ollama",
        "model": "huihui-ai/Huihui-gemma-4-E2B-it-abliterated",
        "apiBase": "http://127.0.0.1:11434"
      }
    }
  '';

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

      # 2. Resolve CPU Sensor Path
      CPU_TEMP_FILE=$(find /sys/class/hwmon/ -name "temp1_input" | grep -v "amdgpu" | grep -v "nvme" | head -n 1)

      CPU_TEMP_DIR=$(grep -l "k10temp" /sys/class/hwmon/hwmon*/name 2>/dev/null | awk -F/ '{print "/sys/class/hwmon/" $5 "/temp1_input"}')
      if [ -f "$CPU_TEMP_DIR" ]; then
          CPU_TEMP_FILE="$CPU_TEMP_DIR"
      fi

      CPU_TEMP=0
      if [ -f "$CPU_TEMP_FILE" ]; then
          CPU_TEMP=$(( $(cat "$CPU_TEMP_FILE") / 1000 ))
      fi

      # 3. Resolve GPU Sensor Paths
      GPU_BUSY_PATH="/sys/class/drm/card1/device/gpu_busy_percent"
      GPU_TEMP_FILE=$(find /sys/class/drm/card1/device/hwmon/ -name "temp1_input" 2>/dev/null | head -n 1)

      GPU_UTIL=0
      if [ -f "$GPU_BUSY_PATH" ]; then
          GPU_UTIL=$(cat "$GPU_BUSY_PATH")
      fi

      GPU_TEMP=0
      if [ -f "$GPU_TEMP_FILE" ]; then
          GPU_TEMP=$(( $(cat "$GPU_TEMP_FILE") / 1000 ))
      fi

      TEXT=" ''${CPU_UTIL}% (''${CPU_TEMP}°C)  󰾲 ''${GPU_UTIL}% (''${GPU_TEMP}°C)"
      TOOLTIP=$(printf "System Status:\n\nCPU Usage: %s%%\nCPU Temp: %s°C\n\nGPU Usage: %s%%\nGPU Temp: %s°C" "$CPU_UTIL" "$CPU_TEMP" "$GPU_UTIL" "$GPU_TEMP")

      ${pkgs.jq}/bin/jq -n -c --arg text "$TEXT" --arg tooltip "$TOOLTIP" '{text: $text, tooltip: $tooltip}'
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

        FULL_TOOLTIP=$(printf "%s\nCycle: %s" "$tooltip" "$cycles")
        ${pkgs.jq}/bin/jq -n -c --arg text "$display_text" --arg tooltip "$FULL_TOOLTIP" --arg class "$class" '{text: $text, tooltip: $tooltip, class: $class}'
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

  # 12. Declarative VS Code configuration (extensions + theme)

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

  # Starship Prompt Configuration
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

  # SwayNC notification center setup (MD3 glassmorphic design with floating margins)
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
    '';
  };

  # 14. Declarative XDG user directories (auto-creation on login)
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
  };

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  xdg.configFile."MangoHud/MangoHud.conf".force = true;

  programs.mangohud = {
    enable = true;
    settings = {
      toggle_hud = "Shift_R+F12";
      legacy_layout = 0;
      horizontal = true;
      hud_no_margin = true;
      font_size = 28;
      table_columns = 3;
      background_alpha = "0.5";
      round_corners = 10;
      # Performance Stats
      fps = true;
      fps_metrics = "avg,0.01,0.05";
      frametime = true;
      cpu_stats = true;
      cpu_temp = true;
      cpu_mhz = true;
      cpu_power = true;
      gpu_stats = true;
      gpu_temp = true;
      gpu_core_clock = true;
      gpu_power = true;
      ram = true;
      vram = true;
      vulkan_driver = true;
      wine = true;
    };
  };

  home.file.".steam/root/compatibilitytools.d/proton-ge-custom".source = "${pkgs.proton-ge-bin}";

  # Carapace multi-shell completer for 500+ CLI tools (Git, Nix, Docker, Cargo, Systemctl, etc.)
  programs.carapace = {
    enable = true;
    enableNushellIntegration = true;
  };

  # FZF fuzzy history and file finder integration
  programs.fzf = {
    enable = true;
    enableNushellIntegration = false;
  };

  # Nushell configuration with IDE-like completion menus & intellisense
  programs.nushell = {
    enable = true;
    extraConfig = ''
      $env.TZ = "Europe/Warsaw"
      macchina

      $env.config = {
        show_banner: false
        completions: {
          case_sensitive: false
          quick: true
          partial: true
          algorithm: "fuzzy"
          external: {
            enable: true
            max_results: 100
            completer: {|spans|
              carapace $spans.0 nushell ...$spans | from json
            }
          }
        }
      }

    '';
  };

  systemd.user.services.awww-daemon = {
    Unit = {
      Description = "Animated Wallpaper Daemon (awww)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f /run/user/%U/*awww-daemon.sock";
      ExecStart = "${pkgs.awww}/bin/awww-daemon";
      Restart = "on-failure";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  home.stateVersion = "26.05";
}
