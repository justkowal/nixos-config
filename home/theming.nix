{ config, pkgs, lib, ... }: {

  # Matugen Material You Dynamic Theming Templates
  # All templates are processed by matugen to generate theme files for
  # each application from wallpaper-extracted Material Design 3 colors.

  # --- Starship Prompt ---
  xdg.configFile."matugen/templates/starship.toml".text = builtins.readFile ./matugen/templates/starship.toml;

  # --- VS Code Theme ---
  xdg.configFile."matugen/templates/vscode-theme.json".text = builtins.readFile ./matugen/templates/vscode-theme.json;

  # --- Firefox Material Blue CSS ---
  xdg.configFile."matugen/templates/theme-material-blue.css".text = builtins.readFile ./matugen/templates/theme-material-blue.css;

  # --- Waybar Colors ---
  xdg.configFile."matugen/templates/waybar-colors.css".text = builtins.readFile ./matugen/templates/waybar-colors.css;

  # --- Hyprland Colors ---
  xdg.configFile."matugen/templates/hyprland-colors.conf".text = builtins.readFile ./matugen/templates/hyprland-colors.conf;

  # --- Kitty Colors ---
  xdg.configFile."matugen/templates/kitty-colors.conf".text = builtins.readFile ./matugen/templates/kitty-colors.conf;

  # --- Rofi Colors ---
  xdg.configFile."matugen/templates/rofi-colors.rasi".text = builtins.readFile ./matugen/templates/rofi-colors.rasi;

  # --- SwayNC Colors ---
  xdg.configFile."matugen/templates/swaync-colors.css".text = builtins.readFile ./matugen/templates/swaync-colors.css;

  # --- VS Code raw color data ---
  xdg.configFile."matugen/templates/vscode-colors".text = builtins.readFile ./matugen/templates/vscode-colors;

  # --- VS Code JSON color data ---
  xdg.configFile."matugen/templates/vscode-colors.json".text = builtins.readFile ./matugen/templates/vscode-colors.json;

  # --- GTK3 Colors ---
  xdg.configFile."matugen/templates/gtk3.css".text = builtins.readFile ./matugen/templates/gtk3.css;

  # --- GTK4 Colors ---
  xdg.configFile."matugen/templates/gtk4.css".text = builtins.readFile ./matugen/templates/gtk4.css;

  # --- Btop Theme ---
  xdg.configFile."matugen/templates/btop.theme".text = builtins.readFile ./matugen/templates/btop.theme;

  # --- Steam CSS ---
  xdg.configFile."matugen/templates/steam.css".text = builtins.readFile ./matugen/templates/steam.css;

  # --- KDE/Qt Color Scheme (for Dolphin and all KDE/Qt apps) ---
  xdg.configFile."matugen/templates/kde-colors.colors".text = builtins.readFile ./matugen/templates/kde-colors.colors;

  # Matugen Configuration (template → output path mappings)

  xdg.configFile."matugen/config.toml".text = builtins.readFile ./matugen/config.toml;

  # Matugen template for Discord / Vencord / Vesktop (InioX matugen-themes)
  xdg.configFile."matugen/templates/discord.css".text = builtins.readFile ./matugen/templates/discord.css;

  # Matugen template for Heroic Games Launcher (InioX matugen-themes)
  xdg.configFile."matugen/templates/heroic.css".text = builtins.readFile ./matugen/templates/heroic.css;

  # Matugen template for Prism Launcher (InioX matugen-themes)
  xdg.configFile."matugen/templates/prismlauncher.json".text = builtins.readFile ./matugen/templates/prismlauncher.json;

  # Matugen template for Anki (InioX matugen-themes)
  xdg.configFile."matugen/templates/anki.css".text = builtins.readFile ./matugen/templates/anki.css;

  # Matugen template for Zathura PDF Viewer (InioX matugen-themes)
  xdg.configFile."matugen/templates/zathura-colors".text = builtins.readFile ./matugen/templates/zathura-colors;

  # Matugen template for Spotify Spicetify Sleek (InioX matugen-themes)
  xdg.configFile."matugen/templates/spicetify.ini".text = builtins.readFile ./matugen/templates/spicetify.ini;

  # Matugen template for GTK Colors (InioX matugen-themes)
  xdg.configFile."matugen/templates/gtk-colors.css".text = builtins.readFile ./matugen/templates/gtk-colors.css;

  # Vencord / Vesktop QuickCSS Configuration
  xdg.configFile."Vencord/settings/settings.json".text = builtins.readFile ./discord/vencord-settings.json;

  xdg.configFile."vesktop/settings/settings.json".text = builtins.readFile ./discord/vesktop-settings.json;

  # KDE/Qt Color Scheme Integration (kdeglobals written dynamically by Matugen)
}
