{ config, pkgs, ... }:

{
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
    gnome-software     # Graphical store for Flatpaks
    discord            # Chat & Social (with Discord Rich Presence support)
    lutris             # Gaming Launcher wrapper
    heroic             # GOG & Epic Games Launcher client
    spotify            # Music streaming client

    # LaTeX typesetting stack (medium scheme provides most standard packages)
    texlive.combined.scheme-medium

    # Desktop Generics
    gnome-calculator   # Calculator
    mousepad           # Simple GUI notepad/editor
    neovim             # Advanced CLI text editor
    file-roller        # Archive manager
    feh                # Lightweight image viewer
    pavucontrol        # PulseAudio volume control (PipeWire compatible)
    btop               # Modern resource monitor (TUI)
    macchina           # System information fetcher (Rust neofetch clone)
    nix-search-cli     # CLI search tool for nixpkgs
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
