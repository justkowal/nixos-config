{
  config,
  lib,
  ...
}: let
  entries = config.lab.keymap.entries;

  # the shortcut for a keymap entry, written the way the help window draws it
  keysOf = label: let
    e = lib.findFirst (e: e.label == label) null entries;
  in
    if e == null
    then ""
    else
      lib.concatStringsSep " + " (
        (map (lib.replaceStrings ["$mod"] ["SUPER"]) (lib.filter (m: m != "") (lib.splitString " " e.mods)))
        ++ [(lib.toUpper e.key)]
      );

  feature = title: text: keys: {inherit title text keys;};
in {
  options.lab.help.features = lib.mkOption {
    type = lib.types.listOf (lib.types.attrsOf lib.types.str);
    default = [];
    description = "Cards on the help window's Features page. keys is a keymap label looked up for you, or empty.";
  };

  config = {
    lab.help.features = [
      (feature "Command palette" "Search apps, saved rooms, actions and scenes. Type anything for a web search. Type save and a name to save the current workspace as a room. It is the place for everything that does not have its own key." (keysOf "Command palette"))
      (feature "Rooms" "A room is a saved layout of your windows for one project: which terminals (and their folders), apps and browser are open, and where they sit. Save one from the palette, open it from the palette, or send it to your other machine. Received rooms wait in the palette until you accept them. Nothing is restored beyond that, no open files or running commands." "")
      (feature "Scenes" "Welcome back, Focus and Leave change several things at once. Run them from the palette by typing scene." "")
      (feature "Focus" "Fleet-wide focus mode: silences distractions on your machines, keeps the screen awake and starts a pomodoro timer. Start 15, 25, 45 or 60 minutes from the palette, or toggle it with the key." (keysOf "Toggle focus"))
      (feature "The island" "The pill at the top of the screen shows volume, brightness, focus, rooms, scenes, devices and handoff when they change. It never needs a click." "")
      (feature "Devices" "Shows which of your machines are online, and announces when one connects or goes offline." (keysOf "Show devices"))
      (feature "Dashboard" "Agenda, weather, Claude and Gemini usage with graphs, CI, system load and notifications." (keysOf "Toggle dashboard"))
      (feature "Usage limits" "Claude shows live percentages once you have run claude recently. Gemini shows conversation counts. When live data is unavailable the card says what is wrong and what to do." "")
      (feature "Health" "The Health page runs lab doctor and lists what is not working and why. Open it from the palette by typing health." "")
      (feature "Everything else" "If you can do it, it is in the palette: clipboard history, keep awake, pomodoro, tablet display, snapshots, system update, power actions. The Keybinds page lists every shortcut the compositor knows, live." "")
    ];

    lab.keymap.entries = [
      {
        mods = "$mod";
        key = "SLASH";
        exec = "lab publish help.toggle --source keymap";
        group = "Help";
        label = "Keybinds and features";
      }
    ];

    lab.palette.entries = [
      {
        title = "Features overview";
        group = "Help";
        exec = "lab publish help.toggle --source palette --payload '{\"page\":\"features\"}'";
      }
      {
        title = "Health check";
        group = "Help";
        exec = "lab publish help.toggle --source palette --payload '{\"page\":\"health\"}'";
      }
    ];

    xdg.configFile."lab/help.json".text = builtins.toJSON {features = config.lab.help.features;};

    # the help window is the only toplevel labd opens, everything else is a layer surface
    wayland.windowManager.hyprland.extraConfig = ''
      windowrule = float 1, match:class ^(lab\.justkowal\.Labd)$
      windowrule = size 980 720, match:class ^(lab\.justkowal\.Labd)$
      windowrule = center 1, match:class ^(lab\.justkowal\.Labd)$
    '';
  };
}
