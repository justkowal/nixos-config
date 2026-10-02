{
  config,
  pkgs,
  lib,
  ...
}: let
  thinkdotScript = pkgs.writeShellApplication {
    name = "thinkdot";
    checkPhase = "";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gawk
      procps
      jq
      wireplumber
      pipewire
      psmisc
      swaynotificationcenter
    ];
    text = ''
      LED_DIR="/sys/class/leds/tpacpi::lid_logo_dot"
      BRIGHTNESS="$LED_DIR/brightness"
      TRIGGER="$LED_DIR/trigger"
      RUN_DIR="''${XDG_RUNTIME_DIR:-/tmp}"
      PIPE="$RUN_DIR/thinkdot.pipe"
      STEALTH_FILE="$RUN_DIR/thinkdot.stealth"
      STATE_FILE="$RUN_DIR/thinkdot.state"

      set_led() {
        if [ -w "$BRIGHTNESS" ]; then
          echo "$1" > "$BRIGHTNESS" 2>/dev/null || true
        fi
      }

      set_trigger() {
        if [ -w "$TRIGGER" ]; then
          if ! grep -q "\[$1\]" "$TRIGGER" 2>/dev/null; then
            echo "$1" > "$TRIGGER" 2>/dev/null || true
          fi
        fi
      }

      do_burst() {
        local count="''${1:-3}"
        set_trigger "none"
        for _ in $(seq 1 "$count"); do
          set_led 255
          sleep 0.12
          set_led 0
          sleep 0.10
        done
      }

      get_state() {
        # 0. Stealth mode override
        if [ -f "$STEALTH_FILE" ]; then
          echo "STEALTH"
          return
        fi

        # 0. Lid closed & unplugged (backpack safety)
        local lid_closed=0
        if cat /proc/acpi/button/lid/*/state 2>/dev/null | grep -q "closed"; then
          lid_closed=1
        fi
        local ac_online=0
        if [ -f /sys/class/power_supply/AC/online ] && [ "$(cat /sys/class/power_supply/AC/online 2>/dev/null)" = "1" ]; then
          ac_online=1
        fi
        if [ "$lid_closed" -eq 1 ] && [ "$ac_online" -eq 0 ]; then
          echo "BACKPACK"
          return
        fi

        # P1: Privacy / On-Air (Camera or active unmuted Mic)
        local cam_active=0
        if ls /dev/video* >/dev/null 2>&1 && fuser /dev/video* >/dev/null 2>&1; then
          cam_active=1
        fi
        local mic_active=0
        if pw-dump 2>/dev/null | jq -e '.[] | select(.info.props["media.class"] == "Stream/Input/Audio") | .id' >/dev/null 2>&1; then
          if ! wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -qi "MUTED"; then
            mic_active=1
          fi
        fi
        if [ "$cam_active" -eq 1 ] || [ "$mic_active" -eq 1 ]; then
          echo "PRIVACY"
          return
        fi

        # P2: Critical Battery (< 10% and discharging)
        if [ -f /sys/class/power_supply/BAT0/capacity ] && [ -f /sys/class/power_supply/BAT0/status ]; then
          local cap
          cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo 100)
          local bat_stat
          bat_stat=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "")
          if [ "$cap" -le 10 ] && [ "$bat_stat" = "Discharging" ]; then
            echo "CRITICAL_BATTERY"
            return
          fi
        fi

        # P3: Screen Locked
        if pgrep -x hyprlock >/dev/null 2>&1; then
          echo "LOCKED"
          return
        fi

        # P4: Focus / Pomodoro / DND
        local pomodoro_file="$RUN_DIR/waybar-pomodoro"
        if [ -f "$pomodoro_file" ]; then
          local p_status
          p_status=$(grep "^status=" "$pomodoro_file" 2>/dev/null | cut -d= -f2)
          local p_type
          p_type=$(grep "^type=" "$pomodoro_file" 2>/dev/null | cut -d= -f2)
          if [ "$p_status" = "running" ]; then
            if [ "$p_type" = "work" ]; then
              echo "FOCUS_WORK"
              return
            else
              echo "FOCUS_BREAK"
              return
            fi
          fi
        fi
        if [ "$(swaync-client -D 2>/dev/null || echo false)" = "true" ]; then
          echo "FOCUS_DND"
          return
        fi

        # Night mode check: quiet hours (00:00 - 06:59) suppresses notification & charging blinking
        local hour
        hour=$(date +%-H)
        local is_night=0
        if [ "$hour" -lt 7 ]; then
          is_night=1
        fi

        # P5: Unread Notifications
        if [ "$is_night" -eq 0 ]; then
          local unread
          unread=$(swaync-client -c 2>/dev/null || echo 0)
          if [ "$unread" -gt 0 ]; then
            echo "NOTIFICATIONS"
            return
          fi
        fi

        # P6: Battery Charging
        if [ -f /sys/class/power_supply/BAT0/status ]; then
          local stat
          stat=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "")
          if [ "$stat" = "Charging" ]; then
            echo "CHARGING"
            return
          fi
        fi

        echo "IDLE"
      }

      daemon_loop() {
        rm -f "$PIPE"
        mkfifo "$PIPE"
        exec 3<> "$PIPE"

        cleanup() {
          exec 3>&-
          rm -f "$PIPE" "$STATE_FILE"
          set_trigger "none"
          set_led 0
          exit 0
        }
        trap cleanup EXIT INT TERM

        set_trigger "none"
        set_led 0

        while true; do
          local ipc_cmd=""
          if read -r -t 0.1 -u 3 ipc_cmd; then
            case "$ipc_cmd" in
              BURST*)
                local count="''${ipc_cmd#BURST:}"
                count="''${count:-3}"
                do_burst "$count"
                ;;
              STEALTH_ON) touch "$STEALTH_FILE" ;;
              STEALTH_OFF) rm -f "$STEALTH_FILE" ;;
              STEALTH_TOGGLE)
                if [ -f "$STEALTH_FILE" ]; then rm -f "$STEALTH_FILE"; else touch "$STEALTH_FILE"; fi
                ;;
            esac
          fi

          local current_state
          current_state=$(get_state)

          local stealth_active
          stealth_active=$([ -f "$STEALTH_FILE" ] && echo true || echo false)
          echo "{\"state\":\"$current_state\",\"stealth\":$stealth_active}" > "$STATE_FILE.tmp"
          mv -f "$STATE_FILE.tmp" "$STATE_FILE"

          case "$current_state" in
            PRIVACY|FOCUS_WORK|FOCUS_DND)
              set_trigger "none"
              set_led 255
              read -r -t 1.5 -u 3 ipc_cmd || true
              ;;
            IDLE|STEALTH|BACKPACK)
              set_trigger "none"
              set_led 0
              read -r -t 2.0 -u 3 ipc_cmd || true
              ;;
            CHARGING)
              set_trigger "BAT0-charging-blink-full-solid"
              read -r -t 2.0 -u 3 ipc_cmd || true
              ;;
            CRITICAL_BATTERY)
              set_trigger "none"
              for _ in 1 2 3 4 5; do
                set_led 255
                sleep 0.1
                set_led 0
                sleep 0.1
              done
              ;;
            LOCKED)
              set_trigger "none"
              set_led 255
              sleep 0.08
              set_led 0
              sleep 0.12
              set_led 255
              sleep 0.08
              set_led 0
              read -r -t 2.5 -u 3 ipc_cmd || true
              ;;
            NOTIFICATIONS)
              set_trigger "none"
              for _ in 1 2 3; do
                set_led 255
                sleep 0.08
                set_led 0
                sleep 0.10
              done
              read -r -t 4.5 -u 3 ipc_cmd || true
              ;;
            FOCUS_BREAK)
              set_trigger "none"
              set_led 255
              sleep 0.8
              set_led 0
              read -r -t 1.0 -u 3 ipc_cmd || true
              ;;
            *)
              set_trigger "none"
              set_led 0
              read -r -t 1.0 -u 3 ipc_cmd || true
              ;;
          esac

          if [ -n "$ipc_cmd" ]; then
            case "$ipc_cmd" in
              BURST*)
                local count="''${ipc_cmd#BURST:}"
                count="''${count:-3}"
                do_burst "$count"
                ;;
              STEALTH_ON) touch "$STEALTH_FILE" ;;
              STEALTH_OFF) rm -f "$STEALTH_FILE" ;;
              STEALTH_TOGGLE)
                if [ -f "$STEALTH_FILE" ]; then rm -f "$STEALTH_FILE"; else touch "$STEALTH_FILE"; fi
                ;;
            esac
          fi
        done
      }

      case "''${1:-status}" in
        daemon)
          daemon_loop
          ;;
        burst)
          count="''${2:-3}"
          if [ -p "$PIPE" ]; then
            echo "BURST:$count" > "$PIPE" 2>/dev/null || do_burst "$count"
          else
            do_burst "$count"
          fi
          ;;
        stealth)
          action="''${2:-toggle}"
          case "$action" in
            on)
              touch "$STEALTH_FILE"
              [ -p "$PIPE" ] && echo "STEALTH_ON" > "$PIPE" 2>/dev/null || true
              echo "ThinkPad Dot: Stealth mode ENABLED (muted)"
              ;;
            off)
              rm -f "$STEALTH_FILE"
              [ -p "$PIPE" ] && echo "STEALTH_OFF" > "$PIPE" 2>/dev/null || true
              echo "ThinkPad Dot: Stealth mode DISABLED (active)"
              ;;
            toggle)
              if [ -f "$STEALTH_FILE" ]; then
                rm -f "$STEALTH_FILE"
                [ -p "$PIPE" ] && echo "STEALTH_OFF" > "$PIPE" 2>/dev/null || true
                echo "ThinkPad Dot: Stealth mode DISABLED (active)"
              else
                touch "$STEALTH_FILE"
                [ -p "$PIPE" ] && echo "STEALTH_ON" > "$PIPE" 2>/dev/null || true
                echo "ThinkPad Dot: Stealth mode ENABLED (muted)"
              fi
              ;;
            status)
              if [ -f "$STEALTH_FILE" ]; then
                echo "Stealth mode: ON (Muted)"
              else
                echo "Stealth mode: OFF (Active)"
              fi
              ;;
          esac
          ;;
        on)
          set_trigger "none"
          set_led 255
          echo "ThinkPad Dot: ON"
          ;;
        off)
          set_trigger "none"
          set_led 0
          echo "ThinkPad Dot: OFF"
          ;;
        waybar)
          if [ -f "$STATE_FILE" ]; then
            current=$(jq -r '.state // "IDLE"' "$STATE_FILE" 2>/dev/null || echo "IDLE")
            stealth=$(jq -r '.stealth // false' "$STATE_FILE" 2>/dev/null || echo "false")
          else
            current=$(get_state)
            stealth=$([ -f "$STEALTH_FILE" ] && echo "true" || echo "false")
          fi

          if [ "$stealth" = "true" ]; then
            printf '{"text":"󰛅","tooltip":"ThinkPad Dot: Stealth Muted\\nLeft-click: Enable Ambient Dot","class":"stealth","alt":"stealth"}\n'
          else
            case "$current" in
              PRIVACY)
                printf '{"text":"󰛄","tooltip":"ThinkPad Dot: On-Air / Privacy (Mic/Camera Active)\\nLeft-click: Toggle Stealth","class":"privacy","alt":"privacy"}\n'
                ;;
              FOCUS_WORK|FOCUS_DND)
                printf '{"text":"󰛄","tooltip":"ThinkPad Dot: Focus Mode Active\\nLeft-click: Toggle Stealth","class":"focus","alt":"focus"}\n'
                ;;
              FOCUS_BREAK)
                printf '{"text":"󰛄","tooltip":"ThinkPad Dot: Focus Break\\nLeft-click: Toggle Stealth","class":"break","alt":"break"}\n'
                ;;
              CRITICAL_BATTERY)
                printf '{"text":"󰛄","tooltip":"ThinkPad Dot: Critical Battery Alert\\nLeft-click: Toggle Stealth","class":"critical","alt":"critical"}\n'
                ;;
              LOCKED)
                printf '{"text":"󰛄","tooltip":"ThinkPad Dot: Screen Locked\\nLeft-click: Toggle Stealth","class":"locked","alt":"locked"}\n'
                ;;
              NOTIFICATIONS)
                printf '{"text":"󰛄","tooltip":"ThinkPad Dot: Unread Notifications\\nLeft-click: Toggle Stealth","class":"notify","alt":"notify"}\n'
                ;;
              CHARGING)
                printf '{"text":"󰛄","tooltip":"ThinkPad Dot: Battery Charging\\nLeft-click: Toggle Stealth","class":"charging","alt":"charging"}\n'
                ;;
              *)
                printf '{"text":"󰛄","tooltip":"ThinkPad Dot: Idle\\nLeft-click: Toggle Stealth","class":"idle","alt":"idle"}\n'
                ;;
            esac
          fi
          ;;
        status)
          echo "==========================================="
          echo "   ThinkPad Lid Dot Ambient Controller     "
          echo "==========================================="
          echo "Hardware LED:      $LED_DIR"
          echo "Device Writable:   $([ -w "$BRIGHTNESS" ] && echo "YES" || echo "NO (check udev / permissions)")"
          echo "Current Brightness: $(cat "$BRIGHTNESS" 2>/dev/null || echo "N/A")"
          echo "Current Trigger:    $(cat "$TRIGGER" 2>/dev/null || echo "N/A")"
          echo "Stealth Mode:      $([ -f "$STEALTH_FILE" ] && echo "ACTIVE (Muted)" || echo "INACTIVE")"
          echo "Evaluated State:   $(get_state)"
          echo "Daemon Running:    $(pgrep -f "thinkdot.*daemon" >/dev/null && echo "YES" || echo "NO")"
          echo "-------------------------------------------"
          echo "Inputs:"
          echo "  - Camera (/dev/video*): $(ls /dev/video* >/dev/null 2>&1 && fuser /dev/video* >/dev/null 2>&1 && echo "IN USE" || echo "idle")"
          echo "  - Mic Stream:           $(pw-dump 2>/dev/null | jq -e '.[] | select(.info.props["media.class"] == "Stream/Input/Audio") | .id' >/dev/null 2>&1 && echo "RECORDING" || echo "idle")"
          echo "  - Hyprlock:             $(pgrep -x hyprlock >/dev/null 2>&1 && echo "LOCKED" || echo "unlocked")"
          echo "  - Unread Notifs:        $(swaync-client -c 2>/dev/null || echo "N/A")"
          echo "  - Battery:              $(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "?")% ($(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "?"))"
          echo "  - AC Power:             $([ "$(cat /sys/class/power_supply/AC/online 2>/dev/null)" = "1" ] && echo "Plugged in" || echo "On Battery")"
          echo "  - Lid:                  $(cat /proc/acpi/button/lid/*/state 2>/dev/null | tr -d '\n' || echo "N/A")"
          echo "==========================================="
          ;;
        *)
          echo "Usage: thinkdot {status|waybar|burst [N]|stealth [toggle|on|off|status]|on|off}"
          exit 1
          ;;
      esac
    '';
  };
in {
  # 1. Systemd tmpfiles and udev rules for ThinkPad hardware LED non-root access
  systemd.tmpfiles.rules = [
    "z /sys/class/leds/tpacpi::lid_logo_dot/brightness 0666 root root -"
    "z /sys/class/leds/tpacpi::lid_logo_dot/trigger 0666 root root -"
    "z /sys/class/leds/platform::micmute/brightness 0666 root root -"
    "z /sys/class/leds/platform::micmute/trigger 0666 root root -"
    "z /sys/class/leds/platform::mute/brightness 0666 root root -"
    "z /sys/class/leds/platform::mute/trigger 0666 root root -"
    "z /sys/class/leds/tpacpi::kbd_backlight/brightness 0666 root root -"
    "z /sys/class/leds/tpacpi::kbd_backlight/trigger 0666 root root -"
  ];

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="leds", KERNEL=="tpacpi::lid_logo_dot", RUN+="${pkgs.runtimeShell} -c 'chmod a+rw /sys/class/leds/%k/brightness /sys/class/leds/%k/trigger 2>/dev/null || true'"
    ACTION=="add|change", SUBSYSTEM=="leds", KERNEL=="platform::micmute", RUN+="${pkgs.runtimeShell} -c 'chmod a+rw /sys/class/leds/%k/brightness /sys/class/leds/%k/trigger 2>/dev/null || true'"
    ACTION=="add|change", SUBSYSTEM=="leds", KERNEL=="platform::mute", RUN+="${pkgs.runtimeShell} -c 'chmod a+rw /sys/class/leds/%k/brightness /sys/class/leds/%k/trigger 2>/dev/null || true'"
    ACTION=="add|change", SUBSYSTEM=="leds", KERNEL=="tpacpi::kbd_backlight", RUN+="${pkgs.runtimeShell} -c 'chmod a+rw /sys/class/leds/%k/brightness /sys/class/leds/%k/trigger 2>/dev/null || true'"
  '';

  # 2. Add thinkdot CLI to system packages
  environment.systemPackages = [thinkdotScript];

  # 3. Systemd User Service for thinkpad-dotd ambient controller daemon
  systemd.user.services.thinkpad-dotd = {
    description = "ThinkPad Lid LED Dot Ambient Controller";
    wantedBy = ["default.target"];
    after = ["wireplumber.service" "pipewire.service"];
    serviceConfig = {
      ExecStart = "${thinkdotScript}/bin/thinkdot daemon";
      Restart = "always";
      RestartSec = "3";
    };
  };
}
