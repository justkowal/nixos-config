{ config, pkgs, ... }:

{
  home.username = "justkowal";
  home.homeDirectory = "/home/justkowal";

  # Global developer session variables
  home.sessionVariables = {
    RUSTC_WRAPPER = "${pkgs.sccache}/bin/sccache";
  };

  # User packages
  home.packages = with pkgs; [
    swaynotificationcenter # SwayNC notifications
    swww                   # Animated wallpaper daemon
    wl-clipboard           # Wayland clipboard utilities
    outfit                 # Modern sans-serif font for MD3 layouts
    playerctl              # CLI media player controller
    grim                   # Screen grabber
    slurp                  # Region selector
    libnotify              # Notification sender (notify-send)
    sccache                # Shared compilation cache for C++/Rust
  ];

  # 1. Kitty Terminal configuration (Catppuccin Mocha + transparency)
  programs.kitty = {
    enable = true;
    theme = "Catppuccin-Mocha";
    font = {
      name = "JetBrainsMono Nerd Font";
      size = 11;
    };
    settings = {
      background_opacity = "0.85";
      enable_audio_bell = false;
      confirm_os_window_close = 0;
    };
  };

  # 2. Rofi Launcher (Rofi Wayland styled with Material Design 3 cards)
  programs.rofi = {
    enable = true;
    package = pkgs.rofi-wayland;
    theme = let
      # Define a custom MD3 Catppuccin Mocha theme inside rofi syntax
      inherit (config.lib.formats.rasi) mkLiteral;
    in {
      "*" = {
        bg-col = mkLiteral "#1e1e2e";
        border-col = mkLiteral "#cba6f7";
        selected-col = mkLiteral "#313244";
        text-col = mkLiteral "#cdd6f4";
        accent-col = mkLiteral "#cba6f7";
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
        children = map mkLiteral [ "inputbar" "listview" ];
      };

      "inputbar" = {
        background-color = mkLiteral "@selected-col";
        border-radius = mkLiteral "24px"; # Pill-shaped input bar
        padding = mkLiteral "10px 15px";
        margin = mkLiteral "0px 0px 15px 0px";
        children = map mkLiteral [ "prompt" "entry" ];
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
    settings = [{
      layer = "top";
      position = "top";
      height = 36;
      margin-top = 8;
      margin-left = 12;
      margin-right = 12;
      modules-left = [ "hyprland/workspaces" "hyprland/submap" ];
      modules-center = [ "clock" ];
      modules-right = [ "pulseaudio" "cpu" "memory" "tray" ];

      "hyprland/workspaces" = {
        disable-scroll = true;
        all-outputs = true;
        format = "{name}";
      };

      "clock" = {
        format = "{:%H:%M  |  %d.%m.%Y}";
        tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
      };

      "pulseaudio" = {
        format = "󰕾 {volume}%";
        format-muted = "󰝟 Muted";
        on-click = "pavucontrol";
      };

      "cpu" = {
        format = " {usage}%";
      };

      "memory" = {
        format = " {percentage}%";
      };
    }];

    # MD3 Expressive Glassmorphic Waybar Style
    style = ''
      * {
        font-family: "Outfit", "JetBrainsMono Nerd Font", sans-serif;
        font-size: 13px;
        font-weight: bold;
        border: none;
        border-radius: 0;
      }

      window#waybar {
        background-color: rgba(30, 30, 46, 0.75); /* Catppuccin Mocha Base with 75% opacity */
        border: 2px solid rgba(203, 166, 247, 0.4); /* Mauve border with opacity */
        border-radius: 20px; /* Fully rounded MD3 container */
        color: #cdd6f4;
        transition-property: background-color;
        transition-duration: .5s;
      }

      #workspaces button {
        padding: 0 10px;
        color: #a6adc8;
        background-color: transparent;
        border-radius: 12px;
        margin: 4px 2px;
      }

      #workspaces button.active {
        color: #cba6f7;
        background-color: #313244;
      }

      #clock, #pulseaudio, #cpu, #memory, #tray {
        padding: 0 16px;
        margin: 4px 2px;
        background-color: #313244;
        border-radius: 12px;
      }

      #clock {
        color: #b4befe;
      }

      #pulseaudio {
        color: #a6e3a1;
      }

      #cpu {
        color: #f9e2af;
      }

      #memory {
        color: #89dceb;
      }
    '';
  };

  # 4. Hyprland Window Manager setup (gaps, shadows, active blur, rounded borders)
  wayland.windowManager.hyprland = {
    enable = true;
    settings = {
      # 100% monitor resolution auto-detection with high refresh rate
      monitor = [ ",preferred,auto,1" ];

      general = {
        gaps_in = 6;
        gaps_out = 12;
        border_size = 2;
        "col.active_border" = "rgba(cba6f7ee) rgba(89b4faee) 45deg"; # Mauve to Blue gradient
        "col.inactive_border" = "rgba(585b70aa)";
        layout = "dwindle";
      };

      decoration = {
        rounding = 14; # Rich MD3 rounded window corners

        # Glassmorphic active blur
        blur = {
          enabled = true;
          size = 8;
          passes = 3;
          new_optimizations = true;
        };

        # Drop shadows for window depth/heirarchy
        drop_shadow = true;
        shadow_range = 15;
        shadow_render_power = 3;
        "col.shadow" = "rgba(11111b66)";
      };

      animations = {
        enabled = true;
        # Sleek spring animations for fast, smooth desktop feeling
        bezier = "myBezier, 0.05, 0.9, 0.1, 1.05";
        animation = [
          "windows, 1, 5, myBezier"
          "windowsOut, 1, 5, default, popin 80%"
          "border, 1, 10, default"
          "fade, 1, 7, default"
          "workspaces, 1, 5, default"
        ];
      };

      # Autostart bar and wallpaper daemon
      exec-once = [
        "waybar"
        "swww init"
        "swaync"
        "wl-paste --type text --watch cliphist store" # Start clipboard store daemon
        "wl-paste --type image --watch cliphist store"
      ];

      # Basic bind configurations
      "$mod" = "SUPER";
      bind = [
        "$mod, RETURN, exec, kitty"
        "$mod, D, exec, rofi -show drun"
        "$mod, Q, killactive,"
        "$mod, M, exit,"
        "$mod, F, togglefloating,"
        "$mod, L, exec, hyprlock" # Lock screen manual hotkey
        "$mod, left, movefocus, l"
        "$mod, right, movefocus, r"
        "$mod, up, movefocus, u"
        "$mod, down, movefocus, d"

        # Clipboard history menu
        "$mod, V, exec, cliphist list | rofi -dmenu | cliphist decode | wl-copy"

        # Screenshots (grim + slurp selection -> copy to clipboard + notify)
        ", Print, exec, grim -g \"$(slurp)\" - | wl-copy && notify-send \"Screenshot\" \"Region copied to clipboard\""
      ];

      # Hardware media keybindings (active even when locked)
      bindl = [
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ", XF86AudioPlay, exec, playerctl play-pause"
        ", XF86AudioNext, exec, playerctl next"
        ", XF86AudioPrev, exec, playerctl previous"
      ];

      bindle = [
        ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
        ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
      ];

      # Workspaces bind
      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];
    };
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
      background = [{
        path = "screenshot"; # Blur the actual current screen state
        blur_passes = 3;
        blur_size = 8;
      }];
      input-field = [{
        size = "250, 60";
        outline_thickness = 2;
        dots_size = 0.2;
        dots_spacing = 0.2;
        fade_on_empty = false;
        outer_color = "rgba(203, 166, 247, 1.0)"; # Mauve outline
        inner_color = "rgba(30, 30, 46, 0.9)";     # Dark background
        font_color = "rgba(205, 214, 244, 1.0)";   # Text color
        placeholder_text = "<i>Password...</i>";
      }];
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
    name = "catppuccin-mocha-mauve-cursors";
    package = pkgs.catppuccin-cursors.mochaMauve;
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  # 9. Declarative GTK & Qt application themes (Mocha + Mauve)
  gtk = {
    enable = true;
    theme = {
      name = "Catppuccin-Mocha-Standard-Mauve-Dark";
      package = pkgs.catppuccin-gtk.override {
        accents = [ "mauve" ];
        size = "standard";
        tweaks = [ "rimless" ];
        variant = "mocha";
      };
    };
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
  };

  # Ensure Qt applications follow GTK theme styling
  qt = {
    enable = true;
    platformTheme.name = "gtk";
  };

  # 10. Git Credentials Configuration
  programs.git = {
    enable = true;
    userName = "justkowal";
    userEmail = "justkowal@users.noreply.github.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };

  # 11. Declarative VS Code configuration (extensions + theme)
  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
    extensions = with pkgs.vscode-extensions; [
      catppuccin.catppuccin-vscode
      bbenoist.nix
      kamadorueda.alejandra # Declarative formatter for Nix configurations
    ];
    userSettings = {
      "workbench.colorTheme" = "Catppuccin Mocha";
      "editor.fontSize" = 13;
      "editor.fontFamily" = "'JetBrainsMono Nerd Font', 'monospace'";
      "editor.formatOnSave" = true;
      "nix.enableLanguageServer" = true;
      "nix.serverPath" = "nixd"; # Language server for Nix IDE
    };
  };

  # 12. Nushell Profile Configuration (disable banner, auto-run macchina)
  programs.nushell = {
    enable = true;
    configFile.text = ''
      # Disable Nushell welcome banner
      $env.config = {
        show_banner: false
      }
      # Welcome user with system statistics on startup
      macchina
    '';
  };

  # 13. Declarative XDG user directories (auto-creation on login)
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
  };

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  home.stateVersion = "26.05";
}
