{
  config,
  pkgs,
  lib,
  laptop ? false,
  ...
}: let
  user = "justkowal";
  homeDir = "/home/${user}";
in {
  imports =
    [
      ./home-hyprland.nix
      ./home-waybar.nix
      ./home-shell.nix
      ./home-apps.nix
      ./home-theming.nix
    ]
    ++ lib.optionals (!laptop) [
      ./home-ai.nix
    ];

  home.username = user;
  home.homeDirectory = homeDir;
  home.enableNixpkgsReleaseCheck = false;

  home.activation = {
    createCadEdaDirs = lib.hm.dag.entryAfter ["writeBoundary"] ''
      mkdir -p ${homeDir}/.local/share/FreeCAD/v1-1/Gui/Stylesheets
      mkdir -p ${homeDir}/.config/kicad/10.0/colors
      mkdir -p ${homeDir}/.local/share/Steam/steamui/skins
      mkdir -p ${homeDir}/.local/share/millennium
      ln -sfn ${homeDir}/.local/share/Steam/steamui/skins ${homeDir}/.local/share/millennium/themes

      THEME_DIR="${homeDir}/.local/share/Steam/steamui/skins/Material-Theme"
      if [ ! -d "$THEME_DIR" ]; then
        ${pkgs.git}/bin/git clone https://github.com/kuska1/Material-Theme.git "$THEME_DIR"
      fi
    '';

    initMatugenColors = lib.hm.dag.entryAfter ["writeBoundary"] ''
      if [ ! -f ${homeDir}/.config/hypr/matugen.conf ]; then
        mkdir -p ${homeDir}/.config/hypr
        cat << 'EOF' > ${homeDir}/.config/hypr/matugen.conf
$background = rgba(1a1111ff)
$background_transparent = rgba(1a1111cc)
$surface = rgba(1a1111ff)
$surface_variant = rgba(524343ff)
$on_surface = rgba(f0dedeff)
$primary = rgba(ffb3b5ff)
$secondary = rgba(e6bdbdff)
$tertiary = rgba(e6c18dff)
$outline = rgba(9f8c8cff)
EOF
      fi

      if [ ! -f ${homeDir}/Pictures/wallpaper.png ]; then
        mkdir -p ${homeDir}/Pictures
        cp ${./wallpaper.png} ${homeDir}/Pictures/wallpaper.png
      fi
    '';

    # MangoHud needs a mutable config file (not a symlink)
    copyMangoHud = lib.hm.dag.entryAfter ["linkGeneration"] ''
      if [ -L ${homeDir}/.config/MangoHud/MangoHud.conf ]; then
        TARGET_PATH=$(readlink -f ${homeDir}/.config/MangoHud/MangoHud.conf)
        if [ -n "$TARGET_PATH" ] && [ -f "$TARGET_PATH" ]; then
          rm -f ${homeDir}/.config/MangoHud/MangoHud.conf
          cp -L "$TARGET_PATH" ${homeDir}/.config/MangoHud/MangoHud.conf
          chmod 644 ${homeDir}/.config/MangoHud/MangoHud.conf
        fi
      fi
    '';
  };

  home.sessionVariables = {
    TZ = "Europe/Warsaw";
    RUSTC_WRAPPER = "${pkgs.sccache}/bin/sccache";
    STARSHIP_CONFIG = "${homeDir}/.config/starship.toml";
    GTK_THEME = "Adwaita:dark";
    MANGOHUD_CONFIGFILE = "${homeDir}/.config/MangoHud/MangoHud.conf";
    ANKI_NIGHT_MODE = "1";
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_DRIVER_PATH = "${pkgs.playwright-driver}";
    PLAYWRIGHT_DRIVER_DOWNLOAD_HOST = "";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  };

  home.packages = with pkgs; [
    awww
    wl-clipboard
    playerctl
    grim
    slurp
    libnotify
    libcanberra-gtk3
    glow
    sccache
    matugen
    gnome-calendar
    gnome-control-center
    jq
    ddcutil
    playwright-driver
    playwright-driver.browsers
    easyeffects
    (buildFHSEnv {
      name = "playwright-fhs";
      targetPkgs = pkgs: with pkgs; [playwright-driver];
      runScript = "bash";
    })
  ];

  programs.home-manager.enable = true;

  home.stateVersion = "26.05";
}
