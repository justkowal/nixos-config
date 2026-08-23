{ pkgs, ... }:

let
  # Script wrappers — installed on PATH as commands
  volume-osd = pkgs.writeShellApplication {
    name = "volume-osd";
    runtimeInputs = with pkgs; [ wireplumber gawk gnugrep libnotify ];
    text = builtins.readFile ./scripts/volume-osd.sh;
  };

  brightness-osd = pkgs.writeShellApplication {
    name = "brightness-osd";
    runtimeInputs = with pkgs; [ ddcutil gnugrep libnotify ];
    text = builtins.readFile ./scripts/brightness-osd.sh;
  };

  power-menu = pkgs.writeShellApplication {
    name = "power-menu";
    runtimeInputs = with pkgs; [ rofi hyprlock hyprland ];
    text = builtins.readFile ./scripts/power-menu.sh;
  };

  change-wallpaper = pkgs.writeShellApplication {
    name = "change-wallpaper";
    runtimeInputs = with pkgs; [ findutils coreutils awww matugen libnotify ];
    text = builtins.readFile ./scripts/change-wallpaper.sh;
  };

  resize-split = pkgs.writeShellApplication {
    name = "resize-split";
    runtimeInputs = with pkgs; [ jq hyprland coreutils ];
    text = builtins.readFile ./scripts/resize-split.sh;
  };
in
{
  home.packages = [
    volume-osd
    brightness-osd
    power-menu
    change-wallpaper
    resize-split
  ];

  wayland.windowManager.hyprland = {
    enable = true;
    configType = "hyprlang";
    extraConfig = ''
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
          vrr = 2
          vfr = true
      }

      cursor {
          no_hardware_cursors = false
      }

      render {
          direct_scanout = true
          explicit_sync = 1
      }

      # Autostart
      exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
      exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
      exec-once = ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --start --components=secrets,pkcs11,ssh
      exec-once = systemctl --user start waybar
      exec-once = sleep 0.5 && awww img /home/justkowal/Pictures/wallpaper.png --transition-type wipe --transition-step 90
      exec-once = blueman-applet
      exec-once = [workspace special:term silent] kitty --class scratchpad

      $mod = SUPER
      bind = $mod, RETURN, exec, kitty
      bind = $mod, B, exec, firefox
      bind = $mod, ESCAPE, exec, power-menu
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

      # Workspaces
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

      # Mouse side buttons
      bind = $mod, mouse:275, workspace, r-1
      bind = $mod, mouse:276, workspace, r+1
      bind = $mod SHIFT, mouse:275, movetoworkspace, r-1
      bind = $mod SHIFT, mouse:276, movetoworkspace, r+1

      # Clipboard & AI
      bind = $mod, V, exec, bash ~/.config/hypr/scripts/cliphist_picker.sh
      bind = $mod ALT, N, exec, bash ~/.config/ai/notification_digest.sh
      bind = $mod SHIFT, S, exec, bash ~/.config/hypr/scripts/ai_ocr_screenshot.sh
      bind = , Print, exec, ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp)" - | ${pkgs.wl-clipboard}/bin/wl-copy && ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i camera-shutter 2>/dev/null && ${pkgs.libnotify}/bin/notify-send "Screenshot" "Region copied to clipboard"
      bind = SHIFT, Print, exec, ${pkgs.grim}/bin/grim - | ${pkgs.wl-clipboard}/bin/wl-copy && ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i camera-shutter 2>/dev/null && ${pkgs.libnotify}/bin/notify-send "Screenshot" "Fullscreen copied to clipboard"
      bind = CTRL, Print, exec, ${pkgs.grim}/bin/grim -g "$(${pkgs.hyprland}/bin/hyprctl activewindow -j | ${pkgs.jq}/bin/jq -r '([.at[0],.at[1]]|join(",")) + " " + ([.size[0],.size[1]]|join("x"))')" - | ${pkgs.wl-clipboard}/bin/wl-copy && ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i camera-shutter 2>/dev/null && ${pkgs.libnotify}/bin/notify-send "Screenshot" "Focused window copied to clipboard"

      bind = $mod SHIFT, W, exec, change-wallpaper

      # Media & volume keys
      bindl = , XF86AudioMute, exec, volume-osd mute
      bindl = , XF86AudioPlay, exec, playerctl play-pause
      bindl = , XF86AudioNext, exec, playerctl next
      bindl = , XF86AudioPrev, exec, playerctl previous
      bindle = , XF86AudioRaiseVolume, exec, volume-osd up
      bindle = , XF86AudioLowerVolume, exec, volume-osd down

      # Brightness (SUPER+ALT+PageUp/Down)
      bindle = $mod ALT, Page_Up, exec, brightness-osd up
      bindle = $mod ALT, Page_Down, exec, brightness-osd down

      # Swap windows
      bind = $mod SHIFT, left, swapwindow, l
      bind = $mod SHIFT, right, swapwindow, r
      bind = $mod SHIFT, up, swapwindow, u
      bind = $mod SHIFT, down, swapwindow, d
      bind = $mod SHIFT, H, swapwindow, l
      bind = $mod SHIFT, L, swapwindow, r
      bind = $mod SHIFT, K, swapwindow, u
      bind = $mod SHIFT, J, swapwindow, d

      # Resize
      binde = $mod ALT, left, resizeactive, -30 0
      binde = $mod ALT, right, resizeactive, 30 0
      binde = $mod ALT, up, resizeactive, 0 -30
      binde = $mod ALT, down, resizeactive, 0 30

      # Move floating
      binde = $mod CTRL, left, moveactive, -30 0
      binde = $mod CTRL, right, moveactive, 30 0
      binde = $mod CTRL, up, moveactive, 0 -30
      binde = $mod CTRL, down, moveactive, 0 30

      # Mouse
      bindm = $mod, mouse:272, movewindow
      bindm = $mod, mouse:273, resizewindow

      # Split/Resize submap
      bind = $mod, R, submap, split
      submap = split
      bind = , 1, exec, resize-split width 25
      bind = , 2, exec, resize-split width 33
      bind = , 3, exec, resize-split width 50
      bind = , 4, exec, resize-split width 66
      bind = , 5, exec, resize-split width 75
      bind = , 6, fullscreen, 1
      bind = , H, exec, resize-split height 50
      bind = , F, fullscreen, 1
      bind = , escape, submap, reset
      bind = , return, submap, reset
      bind = $mod, R, submap, reset
      submap = reset

      # Window rules
      windowrule = float 1, match:class ^(pwvucontrol|com\.saivert\.pwvucontrol)$
      windowrule = size 700 500, match:class ^(pwvucontrol|com\.saivert\.pwvucontrol)$
      windowrule = center 1, match:class ^(pwvucontrol|com\.saivert\.pwvucontrol)$

      windowrule = float 1, match:class ^(org\.gnome\.Calendar)$
      windowrule = size 850 600, match:class ^(org\.gnome\.Calendar)$
      windowrule = center 1, match:class ^(org\.gnome\.Calendar)$

      windowrule = float 1, match:class ^(network_tui)$
      windowrule = size 700 500, match:class ^(network_tui)$
      windowrule = center 1, match:class ^(network_tui)$

      windowrule = float 1, match:class ^(scratchpad)$
      windowrule = size 2176 1008, match:class ^(scratchpad)$
      windowrule = center 1, match:class ^(scratchpad)$

      windowrule = no_anim 1, match:class ^(steam_app_.*)$
      windowrule = no_shadow 1, match:class ^(steam_app_.*)$
      windowrule = no_blur 1, match:class ^(steam_app_.*)$
    '';
  };

  programs.hyprlock = {
    enable = true;
    settings = {
      general = {
        disable_loading_bar = true;
        grace = 15;
        hide_cursor = true;
      };
      background = [{
        path = "screenshot";
        blur_passes = 3;
        blur_size = 8;
      }];
      input-field = [{
        size = "250, 60";
        outline_thickness = 2;
        dots_size = 0.2;
        dots_spacing = 0.2;
        fade_on_empty = false;
        outer_color = "rgba(203, 166, 247, 1.0)";
        inner_color = "rgba(30, 30, 46, 0.9)";
        font_color = "rgba(205, 214, 244, 1.0)";
        placeholder_text = "<i>Password...</i>";
      }];
    };
  };

  services.hypridle = {
    enable = true;
    settings = {
      listener = [
        { timeout = 900; on-timeout = "hyprlock"; }
        { timeout = 1800; on-timeout = "hyprctl dispatch dpms off"; on-resume = "hyprctl dispatch dpms on"; }
      ];
    };
  };

  services.cliphist = {
    enable = true;
    allowImages = true;
  };

  # awww wallpaper daemon
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
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
