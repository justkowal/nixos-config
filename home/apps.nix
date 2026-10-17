{ config, pkgs, lib, laptop ? false, ... }:

let
  guisDir = ./scripts/guis;

  typelibPath = lib.makeSearchPath "lib/girepository-1.0" [
    pkgs.gtk4
    pkgs.libadwaita
    pkgs.glib.out
    pkgs.graphene
    pkgs.pango.out
    pkgs.gdk-pixbuf
    pkgs.harfbuzz
    pkgs.gsettings-desktop-schemas
    pkgs.gobject-introspection
  ];

  lan-mouse-gui = pkgs.writeShellApplication {
    name = "lan-mouse-gui";
    runtimeInputs = with pkgs; [
      (python3.withPackages (ps: [ps.pygobject3]))
      gtk4
      libadwaita
      graphene
      pango
      gdk-pixbuf
      gobject-introspection
      lan-mouse
      iputils
      procps
      coreutils
    ];
    checkPhase = "";
    text = ''
      export GI_TYPELIB_PATH="${typelibPath}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      export PYTHONPATH="${guisDir}''${PYTHONPATH:+:$PYTHONPATH}"
      exec python3 "${guisDir}/lan_mouse_gui.py" "$@"
    '';
  };

  tablet-display-gui = pkgs.writeShellApplication {
    name = "tablet-display-gui";
    runtimeInputs = with pkgs; [
      (python3.withPackages (ps: [ps.pygobject3]))
      gtk4
      libadwaita
      graphene
      pango
      gdk-pixbuf
      gobject-introspection
      hyprland
      jq
      coreutils
      swayosd
    ];
    checkPhase = "";
    text = ''
      export GI_TYPELIB_PATH="${typelibPath}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      export PYTHONPATH="${guisDir}''${PYTHONPATH:+:$PYTHONPATH}"
      exec python3 "${guisDir}/tablet_display_gui.py" "$@"
    '';
  };

  fleet-manager-gui = pkgs.writeShellApplication {
    name = "fleet-manager-gui";
    runtimeInputs = with pkgs; [
      (python3.withPackages (ps: [ps.pygobject3]))
      gtk4
      libadwaita
      graphene
      pango
      gdk-pixbuf
      gobject-introspection
      iputils
      kitty
      openssh
      coreutils
      wakeonlan
      curl
    ];
    checkPhase = "";
    text = ''
      export GI_TYPELIB_PATH="${typelibPath}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      export PYTHONPATH="${guisDir}''${PYTHONPATH:+:$PYTHONPATH}"
      exec python3 "${guisDir}/fleet_manager_gui.py" "$@"
    '';
  };

  control-center-gui = pkgs.writeShellApplication {
    name = "control-center-gui";
    runtimeInputs = with pkgs; [
      (python3.withPackages (ps: [ps.pygobject3]))
      gtk4
      libadwaita
      graphene
      pango
      gdk-pixbuf
      gobject-introspection
      wireplumber
      brightnessctl
      ddcutil
      swayosd
      coreutils
      iputils
      procps
      systemd
    ];
    checkPhase = "";
    text = ''
      export GI_TYPELIB_PATH="${typelibPath}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      export PYTHONPATH="${guisDir}''${PYTHONPATH:+:$PYTHONPATH}"
      exec python3 "${guisDir}/control_center_gui.py" "$@"
    '';
  };
  accubattery = pkgs.callPackage ../pkgs/accubattery {};

  batmon = pkgs.writeShellApplication {
    name = "batmon";
    runtimeInputs = with pkgs; [coreutils gnugrep gawk upower];
    checkPhase = "";
    text = builtins.readFile ./scripts/batmon.sh;
  };
in {
  home.packages = [
    batmon
    accubattery
    control-center-gui
    lan-mouse-gui
    fleet-manager-gui
    tablet-display-gui
    pkgs.nixd
    pkgs.alejandra
  ];

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
      repaint_delay = 2;
      input_delay = 0;
      sync_to_monitor = "no";
    };
    extraConfig = "include colors.conf";
  };

  programs.rofi = {
    enable = true;
    package = pkgs.rofi;
    theme = let
      inherit (config.lib.formats.rasi) mkLiteral;
    in {
      "@import" = "/home/justkowal/.config/rofi/colors.rasi";
      "*" = { width = mkLiteral "600px"; font = "Outfit 11"; };
      "window" = {
        background-color = mkLiteral "@bg-col";
        border = mkLiteral "2px";
        border-color = mkLiteral "@border-col";
        border-radius = mkLiteral "16px";
        padding = mkLiteral "20px";
      };
      "mainbox" = {
        background-color = mkLiteral "transparent";
        children = map mkLiteral [ "inputbar" "listview" ];
      };
      "inputbar" = {
        background-color = mkLiteral "@selected-col";
        border-radius = mkLiteral "24px";
        padding = mkLiteral "10px 15px";
        margin = mkLiteral "0px 0px 15px 0px";
        children = map mkLiteral [ "prompt" "entry" ];
      };
      "prompt" = { background-color = mkLiteral "transparent"; text-color = mkLiteral "@accent-col"; margin = mkLiteral "0px 10px 0px 0px"; };
      "entry" = { background-color = mkLiteral "transparent"; text-color = mkLiteral "@text-col"; };
      "listview" = { background-color = mkLiteral "transparent"; columns = 1; lines = 8; cycle = true; };
      "element" = { background-color = mkLiteral "transparent"; text-color = mkLiteral "@text-col"; border-radius = mkLiteral "12px"; padding = mkLiteral "8px 12px"; margin = mkLiteral "2px 0px"; };
      "element-text" = { background-color = mkLiteral "transparent"; text-color = mkLiteral "inherit"; };
      "element selected" = { background-color = mkLiteral "@selected-col"; text-color = mkLiteral "@accent-col"; };
    };
  };

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
      ExtensionSettings = {
        "{446900e4-71c2-419f-a6a7-df9c091e268b}" = {
          installation_mode = "normal_installed";
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/bitwarden-password-manager/latest.xpi";
        };
      };
    };
  };

  # Hardcoded profile ID — matches the existing Firefox profile
  home.file.".mozilla/firefox/1arj8uom.default/user.js".text = ''
    user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
    user_pref("svg.context-properties.content.enabled", true);
    user_pref("userChrome.theme-material", true);
    user_pref("browser.in-content.dark-mode", true);
    user_pref("layout.css.prefers-color-scheme.content-override", 0);
    user_pref("ui.systemUsesDarkTheme", 1);

    /* GPU acceleration */
    user_pref("gfx.webrender.all", true);
    user_pref("gfx.webrender.compositor", true);

    /* VA-API hardware video decode */
    user_pref("media.hardware-video-decoding.enabled", true);
    user_pref("media.ffmpeg.vaapi.enabled", true);

    /* 1GB RAM cache for fast tab switching */
    user_pref("browser.cache.memory.enable", true);
    user_pref("browser.cache.memory.capacity", 1048576);
    user_pref("browser.tabs.remote.warmup.enabled", true);

    /* Disable telemetry */
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

  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
    profiles.default = {
      extensions = with pkgs.vscode-extensions; [
        bbenoist.nix
        kamadorueda.alejandra
        jnoortheen.nix-ide
        mkhl.direnv
      ];
    };
  };

  # userSettings would symlink settings.json into the read-only store, so vs code can't save it.
  # merge instead: nix-declared keys win on every switch, everything set from the ui survives.
  home.activation.vscodeSettings = let
    managed = pkgs.writeText "vscode-managed-settings.json" (builtins.toJSON {
      "workbench.colorTheme" = "Matugen";
      "editor.fontSize" = 13;
      "editor.fontFamily" = "'JetBrainsMono Nerd Font', 'monospace'";
      "editor.formatOnSave" = true;
      "nix.enableLanguageServer" = true;
      "nix.serverPath" = "nixd";
      "nix.formatterPath" = "alejandra";
      "git.enabled" = true;
      "git.path" = "${pkgs.git}/bin/git";
      "git.autofetch" = true;
      "git.confirmSync" = false;
    });
  in
    lib.hm.dag.entryAfter ["writeBoundary"] ''
      f="${config.xdg.configHome}/Code/User/settings.json"
      run mkdir -p "$(dirname "$f")"
      [ -L "$f" ] && run rm "$f"
      [ -s "$f" ] || echo '{}' > "$f"
      # vs code allows jsonc; if comments break jq, leave the file alone rather than clobber it
      if merged=$(${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$f" ${managed} 2>/dev/null); then
        [ -n "''${DRY_RUN:-}" ] || printf '%s\n' "$merged" > "$f"
      else
        warnEcho "vscode settings.json is not plain json, skipped merging managed keys"
      fi
    '';

  # claude desktop rewrites its whole config from memory, so hand edits made while it runs are lost.
  # set mcpServers here instead; the app picks it up on its next start. other keys stay the app's.
  home.activation.claudeMcpServers = let
    servers = pkgs.writeText "claude-mcp-servers.json" (builtins.toJSON {
      playwright = {
        command = "npx";
        args = ["-y" "@playwright/mcp@0.0.83" "--browser" "chromium" "--executable-path" "${pkgs.chromium}/bin/chromium"];
      };
      fetch = {
        command = "uvx";
        args = ["mcp-server-fetch"];
      };
      duckduckgo-search = {
        command = "uvx";
        args = ["duckduckgo-mcp-server"];
      };
      github = {
        command = "npx";
        args = ["-y" "@modelcontextprotocol/server-github"];
      };
      code-review-graph = {
        command = "uvx";
        args = ["code-review-graph" "serve"];
      };
      # only connects while freecad runs its rpc addon; mcp 2.x dropped the fastmcp module it imports
      freecad = {
        command = "uvx";
        args = ["--from" "freecad-robust-mcp" "--with" "mcp<2" "freecad-mcp" "--mode" "xmlrpc"];
      };
    });
  in
    lib.hm.dag.entryAfter ["writeBoundary"] ''
      f="${config.xdg.configHome}/Claude/claude_desktop_config.json"
      run mkdir -p "$(dirname "$f")"
      [ -s "$f" ] || echo '{}' > "$f"
      if merged=$(${pkgs.jq}/bin/jq --slurpfile s ${servers} '.mcpServers = $s[0]' "$f" 2>/dev/null); then
        [ -n "''${DRY_RUN:-}" ] || { printf '%s\n' "$merged" > "$f" && chmod 600 "$f"; }
      else
        warnEcho "claude_desktop_config.json is not valid json, skipped setting mcpServers"
      fi
    '';

  programs.btop = {
    enable = true;
    settings = {
      color_theme = "matugen";
      theme_background = false;
      truecolor = true;
    };
  };

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

  home.pointerCursor = {
    enable = true;
    name = "Vanilla-DMZ";
    package = pkgs.vanilla-dmz;
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  dconf.settings = {
    "org/gnome/desktop/interface".color-scheme = "prefer-dark";
  };

  gtk = {
    enable = true;
    colorScheme = "dark";
    theme.name = "Adwaita";
    iconTheme = { name = "Papirus-Dark"; package = pkgs.papirus-icon-theme; };
    gtk3.extraConfig.gtk-application-prefer-dark-theme = 1;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = 1;
  };

  qt = {
    enable = true;
    platformTheme.name = "gtk3";
  };

  services.udiskie = {
    enable = true;
    tray = "auto";
    automount = true;
    notify = true;
  };

  xdg.userDirs = {
    enable = true;
    createDirectories = true;
  };

  xdg.desktopEntries.discord = {
    name = "Discord";
    genericName = "All-in-one cross-platform voice and text chat";
    comment = "All-in-one voice and text chat (Vesktop)";
    exec = "vesktop %U";
    icon = "vesktop";
    terminal = false;
    type = "Application";
    categories = [ "Network" "InstantMessaging" "Chat" ];
    mimeType = [ "x-scheme-handler/discord" ];
    settings = {
      Keywords = "discord;vencord;electron;chat";
      StartupWMClass = "Vesktop";
    };
  };

  xdg.desktopEntries.control-center-gui = {
    name = "System Control Center";
    genericName = "Apple-Style Quick Settings";
    comment = "System volume, brightness, power profiles, and quick hardware utilities";
    exec = "control-center-gui";
    icon = "preferences-system";
    terminal = false;
    type = "Application";
    categories = [ "Settings" "HardwareSettings" ];
    settings = {
      Keywords = "control;center;volume;brightness;power;battery;tailscale;audio;settings";
    };
  };

  xdg.desktopEntries.lan-mouse-gui = {
    name = "Seamless Mouse Sharing";
    genericName = "Software KVM & Desk Layout";
    comment = "Configure cross-machine mouse/keyboard sharing and physical desk arrangement";
    exec = "lan-mouse-gui";
    icon = "input-mouse";
    terminal = false;
    type = "Application";
    categories = [ "Settings" "HardwareSettings" ];
    settings = {
      Keywords = "mouse;kvm;lan-mouse;screen;sharing;laptop;desk;layout;orientation";
    };
  };

  xdg.desktopEntries.tablet-display-gui = {
    name = "Tablet Display Studio";
    genericName = "Virtual Headless Display Manager";
    comment = "Manage headless virtual displays for Sunshine and Moonlight tablet streaming";
    exec = "tablet-display-gui";
    icon = "video-display";
    terminal = false;
    type = "Application";
    categories = [ "Settings" "HardwareSettings" ];
    settings = {
      Keywords = "tablet;display;sunshine;moonlight;headless;virtual;streaming;ipad";
    };
  };

  xdg.desktopEntries.fleet-manager-gui = {
    name = "Deployment Fleet Center";
    genericName = "NixOS Homelab & Machine Control";
    comment = "Monitor and manage multi-node NixOS machines, services, and connections";
    exec = "fleet-manager-gui";
    icon = "network-server";
    terminal = false;
    type = "Application";
    categories = [ "System" "Settings" ];
    settings = {
      Keywords = "fleet;nixos;homelab;rpi4;thinkpad;services;glance;kuma;git";
    };
  };

  xdg.desktopEntries.accubattery-gui = {
    name = "AccuBattery Studio";
    genericName = "Battery Diagnostics & Health Studio";
    comment = "Advanced Li-ion battery health, real-time graphs, and per-app power consumption";
    exec = "accubattery-gui";
    icon = "battery";
    terminal = false;
    type = "Application";
    categories = [ "Settings" "HardwareSettings" "System" ];
    settings = {
      Keywords = "battery;accubattery;health;charge;power;discharge;wear;caffeine;energy;thinkpad";
    };
  };

  systemd.user.services.accubattery-daemon = {
    Unit = {
      Description = "AccuBattery session detector, telemetry logger and charge alarm";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${accubattery}/bin/accubattery daemon";
      Environment = "PATH=${lib.makeBinPath (with pkgs; [coreutils procps systemd swayosd hyprland])}";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "image/png" = [ "org.gnome.Loupe.desktop" ];
      "image/jpeg" = [ "org.gnome.Loupe.desktop" ];
      "image/jpg" = [ "org.gnome.Loupe.desktop" ];
      "image/webp" = [ "org.gnome.Loupe.desktop" ];
      "image/gif" = [ "org.gnome.Loupe.desktop" ];
      "image/svg+xml" = [ "org.gnome.Loupe.desktop" ];
      "image/bmp" = [ "org.gnome.Loupe.desktop" ];
      "image/tiff" = [ "org.gnome.Loupe.desktop" ];
      "image/avif" = [ "org.gnome.Loupe.desktop" ];
      "image/heif" = [ "org.gnome.Loupe.desktop" ];
      "video/mp4" = [ "vlc.desktop" ];
      "video/x-matroska" = [ "vlc.desktop" ];
      "video/webm" = [ "vlc.desktop" ];
      "video/quicktime" = [ "vlc.desktop" ];
      "video/x-msvideo" = [ "vlc.desktop" ];
      "video/mpeg" = [ "vlc.desktop" ];
      "audio/mpeg" = [ "vlc.desktop" ];
      "audio/flac" = [ "vlc.desktop" ];
      "audio/wav" = [ "vlc.desktop" ];
      "audio/ogg" = [ "vlc.desktop" ];
      "audio/aac" = [ "vlc.desktop" ];
      "audio/m4a" = [ "vlc.desktop" ];
      "application/pdf" = [ "org.pwmt.zathura.desktop" ];
      "text/html" = [ "firefox.desktop" ];
      "x-scheme-handler/http" = [ "firefox.desktop" ];
      "x-scheme-handler/https" = [ "firefox.desktop" ];
      "x-scheme-handler/about" = [ "firefox.desktop" ];
      "x-scheme-handler/unknown" = [ "firefox.desktop" ];
      "application/xhtml+xml" = [ "firefox.desktop" ];
      "application/zip" = [ "org.gnome.FileRoller.desktop" ];
      "application/x-tar" = [ "org.gnome.FileRoller.desktop" ];
      "application/x-gtar" = [ "org.gnome.FileRoller.desktop" ];
      "application/x-gzip" = [ "org.gnome.FileRoller.desktop" ];
      "application/x-bzip2" = [ "org.gnome.FileRoller.desktop" ];
      "application/x-7z-compressed" = [ "org.gnome.FileRoller.desktop" ];
      "application/vnd.rar" = [ "org.gnome.FileRoller.desktop" ];
      "application/x-compressed-tar" = [ "org.gnome.FileRoller.desktop" ];
      "application/x-xz" = [ "org.gnome.FileRoller.desktop" ];
      "application/x-rar" = [ "org.gnome.FileRoller.desktop" ];
      "inode/directory" = [ "thunar.desktop" ];
      "text/plain" = [ "code.desktop" ];
      "text/markdown" = [ "code.desktop" ];
      "application/json" = [ "code.desktop" ];
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = [ "libreoffice-writer.desktop" ];
      "application/msword" = [ "libreoffice-writer.desktop" ];
      "application/vnd.oasis.opendocument.text" = [ "libreoffice-writer.desktop" ];
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = [ "libreoffice-calc.desktop" ];
      "application/vnd.ms-excel" = [ "libreoffice-calc.desktop" ];
      "application/vnd.openxmlformats-officedocument.presentationml.presentation" = [ "libreoffice-impress.desktop" ];
      "x-scheme-handler/lycheeslicer" = [ "Lychee Slicer.desktop" ];
    };
  };
}
