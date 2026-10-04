{
  inputs,
  pkgs,
  ...
}: {
  programs.steam = {
    enable = true;
    package = pkgs.millennium-steam;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
  };

  programs.thunar = {
    enable = true;
    plugins = with pkgs; [
      thunar-archive-plugin
      thunar-volman
      thunar-media-tags-plugin
    ];
  };

  environment.systemPackages = with pkgs; [
    firefox
    thunderbird
    vlc
    gnome-software
    vesktop
    heroic
    lutris
    protonup-qt
    prismlauncher
    spotify
    freecad
    (symlinkJoin {
      name = "blender";
      paths = [pkgsRocm.blender];
      nativeBuildInputs = [makeWrapper];
      postBuild = ''
        wrapProgram $out/bin/blender \
          --set LD_PRELOAD "${rocmPackages.rocm-comgr}/lib/libamd_comgr.so.3"
      '';
    })
    loupe
    zathura
    libreoffice-fresh
    mods
    fd
    rofi-calc
    restic
    tesseract
    kicad
    qmapshack
    obsidian
    moonlight-qt
    lan-mouse
    localsend
    ludusavi
    zellij

    (texlive.combine {inherit (pkgs.texlive) scheme-medium cancel physics siunitx mathtools tcolorbox environ;})
    anki

    gnome-calculator
    neovim
    pwvucontrol
    btop
    macchina
    nix-search-cli

    file-roller
    ffmpegthumbnailer

    inputs.antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
    inputs.antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.google-antigravity-ide
    inputs.antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.google-antigravity-cli
  ];

  programs.obs-studio = {
    enable = true;
    plugins = with pkgs.obs-studio-plugins; [wlrobs obs-vaapi];
  };
}
