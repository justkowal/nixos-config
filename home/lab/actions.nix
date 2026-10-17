{
  config,
  lib,
  laptop ? false,
  ...
}: {
  # things that used to need a terminal or a bar click, reachable from the palette
  lab.palette.entries =
    [
      {
        title = "Focus for 15 minutes";
        group = "Focus";
        exec = "focus on 15";
        glyph = "focus";
      }
      {
        title = "Focus for 25 minutes";
        group = "Focus";
        exec = "focus on 25";
        glyph = "focus";
      }
      {
        title = "Focus for 45 minutes";
        group = "Focus";
        exec = "focus on 45";
        glyph = "focus";
      }
      {
        title = "Focus for 60 minutes";
        group = "Focus";
        exec = "focus on 60";
        glyph = "focus";
      }
      {
        title = "End focus";
        group = "Focus";
        exec = "focus off";
        glyph = "focus";
      }
      {
        title = "Pomodoro: start or pause";
        group = "Timer";
        exec = "pomodoro toggle";
      }
      {
        title = "Pomodoro: skip";
        group = "Timer";
        exec = "pomodoro skip";
      }
      {
        title = "Pomodoro: reset";
        group = "Timer";
        exec = "pomodoro reset";
      }
      {
        title = "Keep awake: toggle";
        group = "Desktop";
        exec = "caffeine toggle";
      }
      {
        title = "Clipboard history";
        group = "Desktop";
        exec = "cliphist-picker";
      }
      {
        title = "Picture in picture";
        group = "Desktop";
        exec = "pip-toggle";
      }
      {
        title = "Control center";
        group = "Apps";
        exec = "control-center-gui";
      }
      {
        title = "Fleet manager";
        group = "Apps";
        exec = "fleet-manager-gui";
      }
      {
        title = "Mouse sharing";
        group = "Apps";
        exec = "lan-mouse-gui";
      }
      {
        title = "Tablet display studio";
        group = "Apps";
        exec = "tablet-display-gui";
      }
      {
        title = "Tablet display: toggle";
        group = "Desktop";
        exec = "tablet-display toggle";
      }
      {
        title = "Time Machine (snapshots)";
        group = "Apps";
        exec = "timemachine-gui";
      }
      {
        title = "Battery health";
        group = "Apps";
        exec = "accubattery-gui";
      }
    ]
    ++ lib.optionals config.lab.handoff.enable [
      {
        title = "Handoff: suspend or resume";
        group = "Devices";
        exec = "home-lan toggle";
        glyph = "handoff";
      }
    ]
    ++ lib.optionals laptop [
      {
        title = "Power mode: toggle ultra low power";
        group = "System";
        exec = "power-mode toggle";
        glyph = "power";
      }
      {
        title = "Switch display mode";
        group = "Desktop";
        exec = "monitor-ctl mode";
      }
      {
        title = "Wake the desktop";
        group = "Devices";
        exec = "wake-desktop";
        glyph = "handoff";
      }
    ]
    ++ lib.optionals (!laptop) [
      {
        title = "Check for a system update";
        group = "System";
        exec = "kitty --class update_stage -e nixos-update-stage";
      }
      {
        title = "Apply the staged system update";
        group = "System";
        exec = "kitty --class update_review -e nixos-update-apply";
      }
    ];
}
