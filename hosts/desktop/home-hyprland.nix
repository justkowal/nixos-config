{
  pkgs,
  lib,
  laptop ? false,
  ...
}: let
  # Script wrappers — installed on PATH as commands
  volume-osd = pkgs.writeShellApplication {
    name = "volume-osd";
    runtimeInputs = with pkgs; [wireplumber gawk gnugrep libnotify coreutils];
    text = builtins.readFile ./scripts/volume-osd.sh;
  };

  brightness-osd = pkgs.writeShellApplication {
    name = "brightness-osd";
    runtimeInputs = with pkgs; [brightnessctl ddcutil gnugrep libnotify coreutils];
    text = builtins.readFile ./scripts/brightness-osd.sh;
  };

  power-menu = pkgs.writeShellApplication {
    name = "power-menu";
    runtimeInputs = with pkgs; [rofi hyprlock hyprland];
    text = builtins.readFile ./scripts/power-menu.sh;
  };

  change-wallpaper = pkgs.writeShellApplication {
    name = "change-wallpaper";
    runtimeInputs = with pkgs; [findutils coreutils awww matugen libnotify];
    text = builtins.readFile ./scripts/change-wallpaper.sh;
  };

  resize-split = pkgs.writeShellApplication {
    name = "resize-split";
    runtimeInputs = with pkgs; [jq hyprland coreutils];
    text = builtins.readFile ./scripts/resize-split.sh;
  };

  cliphist-picker = pkgs.writeShellApplication {
    name = "cliphist-picker";
    runtimeInputs = with pkgs; [cliphist rofi wl-clipboard];
    text = ''
      cliphist list | rofi -dmenu -p "Clipboard" -theme-str 'window {width: 700px;}' | cliphist decode | wl-copy
    '';
  };

  unlock-keyring = pkgs.writers.writePython3Bin "unlock-keyring-tool" {
    libraries = [pkgs.python3Packages.jeepney];
  } ''
    import sys
    from jeepney import DBusAddress, new_method_call
    from jeepney.io.blocking import open_dbus_connection

    password = sys.stdin.read().strip()
    if not password:
        sys.exit(0)

    try:
        conn = open_dbus_connection(bus="SESSION")
        service = DBusAddress(
            "/org/freedesktop/secrets",
            "org.freedesktop.secrets",
            "org.freedesktop.Secret.Service",
        )
        msg = new_method_call(
            service, "OpenSession", "sv", ("plain", ("s", ""))
        )
        _, session_path = conn.send_and_get_reply(msg).body

        guilt_iface = (
            "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface"
        )
        guilt = DBusAddress(
            "/org/freedesktop/secrets",
            "org.freedesktop.secrets",
            guilt_iface,
        )
        secret = (session_path, b"", password.encode(), "text/plain")
        msg_unlock = new_method_call(
            guilt,
            "UnlockWithMasterPassword",
            "o(oayays)",
            ("/org/freedesktop/secrets/collection/login", secret),
        )
        reply = conn.send_and_get_reply(msg_unlock)
        if reply.body:
            print(f"Keyring unlock failed: {reply.body[0]}", file=sys.stderr)
            sys.exit(1)
        print("Keyring successfully unlocked.")
    except Exception as e:
        print(f"Keyring unlock exception: {e}", file=sys.stderr)
        sys.exit(1)
  '';
in {
  home.packages =
    [
      volume-osd
      brightness-osd
      power-menu
      change-wallpaper
      resize-split
      cliphist-picker
    ]
    ++ lib.optionals laptop [pkgs.blueman pkgs.brightnessctl unlock-keyring];

  wayland.windowManager.hyprland = {
    enable = true;
    configType = "hyprlang";
    extraConfig = ''
          monitor=,preferred,auto,1

          # Default fallback colors (overridden by matugen.conf if present)
          $background = rgba(1a1111ff)
          $background_transparent = rgba(1a1111cc)
          $surface = rgba(1a1111ff)
          $surface_variant = rgba(524343ff)
          $on_surface = rgba(f0dedeff)
          $primary = rgba(ffb3b5ff)
          $secondary = rgba(e6bdbdff)
          $tertiary = rgba(e6c18dff)
          $outline = rgba(9f8c8cff)

          source = ~/.config/hypr/matugen.conf

          input {
              kb_layout = pl
              follow_mouse = 1
      ${lib.optionalString laptop ''
        touchpad {
          natural_scroll = true
          tap-to-click = true
          clickfinger_behavior = true
          tap-and-drag = true
          drag_lock = false
          disable_while_typing = true
        }
      ''}
          }

      ${lib.optionalString laptop ''
        gestures {
          workspace_swipe_distance = 200
          workspace_swipe_cancel_ratio = 0.2
          workspace_swipe_min_speed_to_force = 15
          workspace_swipe_forever = true
          workspace_swipe_create_new = true
          workspace_swipe_direction_lock = true
        }

        # 3 and 4-finger touchpad gestures
        gesture = 3, horizontal, workspace
        gesture = 4, horizontal, workspace
        gesture = 3, vertical, special, term
        gesture = 4, vertical, special, term

        device {
          name = etps/2-elantech-trackpoint
          sensitivity = 0.0
          accel_profile = adaptive
        }
      ''}

          general {
            gaps_in = ${
        if laptop
        then "4"
        else "6"
      }
            gaps_out = ${
        if laptop
        then "8"
        else "12"
      }
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
              focus_on_activate = true
          }



          # Autostart
          exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
          exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
          exec-once = ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --start --components=secrets,pkcs11,ssh
        ${lib.optionalString laptop ''
          exec-once = ${pkgs.bash}/bin/bash -c "sleep 1 && if [ -f /etc/keyring.cred ]; then systemctl start unlock-keyring.service; fi"
        ''}
          exec-once = systemctl --user start waybar
          exec-once = ${pkgs.bash}/bin/bash -c "sleep 1 && ${pkgs.awww}/bin/awww img /home/justkowal/Pictures/wallpaper.png --transition-type wipe --transition-step 90 && ${pkgs.matugen}/bin/matugen image --source-color-index 0 /home/justkowal/Pictures/wallpaper.png"
        ${lib.optionalString laptop ''
        exec-once = blueman-applet
      ''}
          exec-once = [workspace special:term silent] kitty --class scratchpad
          exec-once = easyeffects --gapplication-service

          $mod = SUPER
          bind = $mod, RETURN, exec, kitty
          bind = $mod, E, exec, thunar
          bind = $mod, B, exec, firefox
          bind = $mod, ESCAPE, exec, power-menu
          bind = $mod, grave, togglespecialworkspace, term
      ${
        if laptop
        then ''
          bind = $mod, D, exec, rofi -show drun
          bind = $mod, SPACE, exec, rofi -show drun
        ''
        else ''
          bind = $mod, D, exec, bash ~/.config/hypr/scripts/spotlight.sh
          bind = $mod, SPACE, exec, bash ~/.config/hypr/scripts/spotlight.sh
          bind = $mod, A, exec, bash ~/.config/hypr/scripts/rofi_ai.sh
        ''
      }
          bind = $mod, Q, killactive,
          bind = $mod, M, exit,
          bind = $mod, F, togglefloating,
          bind = $mod, L, exec, loginctl lock-session
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
          bind = $mod, V, exec, cliphist-picker
      ${lib.optionalString (!laptop) ''
          bind = $mod ALT, N, exec, bash ~/.config/ai/notification_digest.sh
          bind = $mod SHIFT, S, exec, bash ~/.config/hypr/scripts/ai_ocr_screenshot.sh
      ''}
          bind = , Print, exec, ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp)" - | ${pkgs.wl-clipboard}/bin/wl-copy && ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i camera-shutter 2>/dev/null && ${pkgs.libnotify}/bin/notify-send "Screenshot" "Region copied to clipboard"
          bind = SHIFT, Print, exec, ${pkgs.grim}/bin/grim - | ${pkgs.wl-clipboard}/bin/wl-copy && ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i camera-shutter 2>/dev/null && ${pkgs.libnotify}/bin/notify-send "Screenshot" "Fullscreen copied to clipboard"
          bind = CTRL, Print, exec, ${pkgs.grim}/bin/grim -g "$(${pkgs.hyprland}/bin/hyprctl activewindow -j | ${pkgs.jq}/bin/jq -r '([.at[0],.at[1]]|join(",")) + " " + ([.size[0],.size[1]]|join("x"))')" - | ${pkgs.wl-clipboard}/bin/wl-copy && ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i camera-shutter 2>/dev/null && ${pkgs.libnotify}/bin/notify-send "Screenshot" "Focused window copied to clipboard"

          bind = $mod SHIFT, W, exec, change-wallpaper

          # Media, Volume & Mic keys
          bindl = , XF86AudioMute, exec, volume-osd mute
          bindle = , XF86AudioRaiseVolume, exec, volume-osd up
          bindle = , XF86AudioLowerVolume, exec, volume-osd down
          bindl = , XF86AudioMicMute, exec, volume-osd mic-mute
          bindl = , XF86AudioPlay, exec, playerctl play-pause
          bindl = , XF86AudioNext, exec, playerctl next
          bindl = , XF86AudioPrev, exec, playerctl previous

          # Brightness (Hardware Keys & Mod shortcuts)
          bindle = , XF86MonBrightnessUp, exec, brightness-osd up
          bindle = , XF86MonBrightnessDown, exec, brightness-osd down
          bindle = $mod ALT, Page_Up, exec, brightness-osd up
          bindle = $mod ALT, Page_Down, exec, brightness-osd down

          # ThinkPad Hardware Hotkeys
          bindl = , XF86Display, exec, bash -c "if ${pkgs.hyprland}/bin/hyprctl monitors | grep -q 'DP-'; then ${pkgs.hyprland}/bin/hyprctl dispatch dpms toggle; else ${pkgs.libnotify}/bin/notify-send -i video-display 'Display' 'Single display active'; fi"
          bindl = , XF86WLAN, exec, bash -c "if ${pkgs.networkmanager}/bin/nmcli radio wifi | grep -q 'enabled'; then ${pkgs.networkmanager}/bin/nmcli radio wifi off && ${pkgs.libnotify}/bin/notify-send -i network-wireless-offline 'WiFi' 'Disabled (Airplane Mode)'; else ${pkgs.networkmanager}/bin/nmcli radio wifi on && ${pkgs.libnotify}/bin/notify-send -i network-wireless-signal-excellent 'WiFi' 'Enabled'; fi"
          bind = , XF86Tools, exec, swaync-client -t -sw
          bind = , XF86NotificationCenter, exec, swaync-client -t -sw
          bindl = , XF86Bluetooth, exec, bash -c "if ${pkgs.util-linux}/bin/rfkill list bluetooth | grep -q 'Soft blocked: yes'; then ${pkgs.util-linux}/bin/rfkill unblock bluetooth && ${pkgs.libnotify}/bin/notify-send -i bluetooth-active 'Bluetooth' 'Enabled'; else ${pkgs.util-linux}/bin/rfkill block bluetooth && ${pkgs.libnotify}/bin/notify-send -i bluetooth-disabled 'Bluetooth' 'Disabled'; fi"
          bind = , XF86Favorites, togglespecialworkspace, term

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
          windowrule = float 1, match:title ^(Picture-in-Picture)$
          windowrule = size 400 225, match:title ^(Picture-in-Picture)$
          windowrule = pin 1, match:title ^(Picture-in-Picture)$
          windowrule = move 100%-412 50, match:title ^(Picture-in-Picture)$

          windowrule = float 1, match:class ^(pwvucontrol|com\.saivert\.pwvucontrol)$
          windowrule = size 700 500, match:class ^(pwvucontrol|com\.saivert\.pwvucontrol)$
          windowrule = center 1, match:class ^(pwvucontrol|com\.saivert\.pwvucontrol)$

          windowrule = float 1, match:class ^(org\.gnome\.Calendar)$
          windowrule = size 910 660, match:class ^(org\.gnome\.Calendar)$
          windowrule = center 1, match:class ^(org\.gnome\.Calendar)$

          windowrule = float 1, match:class ^(network_tui)$
          windowrule = size 700 500, match:class ^(network_tui)$
          windowrule = center 1, match:class ^(network_tui)$

          windowrule = float 1, match:class ^(update_review|update_stage)$
          windowrule = size 900 650, match:class ^(update_review|update_stage)$
          windowrule = center 1, match:class ^(update_review|update_stage)$

          windowrule = float 1, match:class ^(scratchpad)$
          windowrule = size 2176 1008, match:class ^(scratchpad)$
          windowrule = center 1, match:class ^(scratchpad)$

          windowrule = no_anim 1, match:class ^(steam_app_.*)$
          windowrule = no_shadow 1, match:class ^(steam_app_.*)$
          windowrule = no_blur 1, match:class ^(steam_app_.*)$

          windowrule = float 1, match:class ^(thunar|Thunar)$, match:title ^(File Operation Progress|Confirm to replace files|Attention)$
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
      auth = lib.mkIf laptop {
        "fingerprint:enabled" = true;
        "fingerprint:ready_message" = "(Scan fingerprint)";
        "fingerprint:present_message" = "Scanning fingerprint...";
      };
      background = [
        {
          path = "screenshot";
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
          outer_color = "rgba(203, 166, 247, 1.0)";
          inner_color = "rgba(30, 30, 46, 0.9)";
          font_color = "rgba(205, 214, 244, 1.0)";
          placeholder_text =
            if laptop
            then "<i>Scan face, fingerprint or password...</i>"
            else "<i>Password...</i>";
        }
      ];
    };
  };

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock --grace 0";
        before_sleep_cmd = "loginctl lock-session; sleep 0.5";
        after_sleep_cmd = "hyprctl dispatch dpms on";
        ignore_dbus_inhibit = false;
      };
      listener = [
        {
          timeout = 900;
          on-timeout = "hyprlock";
        }
        {
          timeout = 1800;
          on-timeout = "hyprctl dispatch dpms off";
          on-resume = "hyprctl dispatch dpms on";
        }
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
      PartOf = ["graphical-session.target"];
      After = ["graphical-session.target"];
    };
    Service = {
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f /run/user/%U/*awww-daemon.sock";
      ExecStart = "${pkgs.awww}/bin/awww-daemon";
      Restart = "on-failure";
    };
    Install.WantedBy = ["graphical-session.target"];
  };
}
