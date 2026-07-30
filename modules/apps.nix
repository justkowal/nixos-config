{
  inputs,
  pkgs,
  ...
}: {
  # Enable Steam gaming platform
  programs.steam = {
    enable = true;
    package = pkgs.millennium-steam;
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
    (discord.override { withVencord = true; }) # Chat & Social (with Vencord custom CSS theme support)
    vesktop # Discord Desktop client with built-in Vencord support
    heroic # GOG & Epic Games Launcher client
    lutris # Open Source gaming platform for Windows/Linux games
    protonup-qt # Graphical manager for Proton-GE and Wine-GE
    prismlauncher # Minecraft launcher
    spotify # Music streaming client
    freecad # 3D CAD modeler
    (symlinkJoin {
      name = "blender";
      paths = [ pkgsRocm.blender ];
      nativeBuildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/blender \
          --set LD_PRELOAD "${rocmPackages.rocm-comgr}/lib/libamd_comgr.so.3"
      '';
    }) # 3D creation suite (wrapped with LD_PRELOAD to fix ROCm/HIP compiler crashes)
    loupe # Modern GTK4 image viewer
    zathura # Minimalist keyboard-driven PDF viewer
    libreoffice-fresh # Modern Office Suite for docx/odt/xlsx/pptx
    mods # CLI AI assistant tool by Charmbracelet
    fd # Ultra-fast file search CLI tool
    rofi-calc # Calculator plugin for Rofi
    restic # High-performance encrypted backup framework
    tesseract # Optical Character Recognition (OCR) engine for AI screenshot parsing
    kicad # EDA suite for schematics and PCB design

    # LaTeX typesetting stack & Anki flashcard suite
    (texlive.combine { inherit (pkgs.texlive) scheme-medium cancel physics siunitx mathtools tcolorbox environ; })
    anki

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
