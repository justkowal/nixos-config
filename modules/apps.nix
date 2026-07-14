{
  inputs,
  pkgs,
  ...
}: {
  # Enable Steam gaming platform
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
  };

  # Application installation list
  environment.systemPackages = with pkgs; [
    # Core GUI Apps
    firefox
    thunderbird
    vlc
    gnome-software # Graphical store for Flatpaks
    discord # Chat & Social (with Discord Rich Presence support)
    lutris # Gaming Launcher wrapper
    heroic # GOG & Epic Games Launcher client
    prismlauncher # Minecraft launcher
    spotify # Music streaming client
    freecad # 3D CAD modeler
    blender # 3D creation suite
    loupe # Modern GTK4 image viewer
    kicad # EDA suite for schematics and PCB design

    # LaTeX typesetting stack (medium scheme provides most standard packages)
    texlive.combined.scheme-medium

    # Desktop Generics
    gnome-calculator # Calculator
    mousepad # Simple GUI notepad/editor
    neovim # Advanced CLI text editor
    file-roller # Archive manager
    feh # Lightweight image viewer
    pwvucontrol # PulseAudio volume control (PipeWire compatible)
    btop # Modern resource monitor (TUI)
    macchina # System information fetcher (Rust neofetch clone)
    nix-search-cli # CLI search tool for nixpkgs

    inputs.antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
    inputs.antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.google-antigravity-ide
    inputs.antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.google-antigravity-cli
  ];

  # OBS Studio configured with Wayland capture (wlrobs) and AMD hardware encoding (obs-vaapi)
  programs.obs-studio = {
    enable = true;
    plugins = with pkgs.obs-studio-plugins; [
      wlrobs
      obs-vaapi
    ];
  };
}
