{
  lib,
  laptop ? false,
  ...
}: {
  config = lib.mkIf laptop {
    lab.keymap.entries = [
      {
        mods = "$mod ALT";
        key = "B";
        exec = "accubattery-gui";
        group = "Battery";
        label = "Battery sessions and health";
        palette = false;
      }
      {
        mods = "$mod ALT SHIFT";
        key = "B";
        exec = "accubattery trip";
        group = "Battery";
        label = "Full charge for a trip";
        palette = false;
      }
    ];

    lab.palette.entries = [
      {
        title = "Battery sessions and health";
        group = "Battery";
        exec = "accubattery-gui";
        glyph = "battery";
      }
      {
        title = "Charge to 100 % for a trip";
        group = "Battery";
        exec = "accubattery trip";
        glyph = "battery";
      }
      {
        title = "Charge limit: back to conservation";
        group = "Battery";
        exec = "accubattery limit conserve";
        glyph = "battery";
      }
      {
        title = "Display power saving: maximum";
        group = "Battery";
        exec = "accubattery abm 4";
        glyph = "brightness";
      }
      {
        title = "Display power saving: off";
        group = "Battery";
        exec = "accubattery abm 0";
        glyph = "brightness";
      }
      {
        title = "Export battery history";
        group = "Battery";
        exec = "accubattery export csv ~/battery-history.csv";
        glyph = "battery";
      }
    ];

    lab.scenes = {
      travel = {
        title = lib.mkDefault "Travel";
        steps = lib.mkDefault ["accubattery trip 24" "accubattery abm 4"];
      };
      desk = {
        title = lib.mkDefault "Desk power";
        steps = lib.mkDefault ["accubattery trip --cancel" "accubattery abm 0"];
      };
    };
  };
}
