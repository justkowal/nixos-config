{ inputs, pkgs, ... }:

{
  programs.steam = {
    enable = true;
    package = pkgs.millennium-steam;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
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
      paths = [ pkgsRocm.blender ];
      nativeBuildInputs = [ makeWrapper ];
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

    (texlive.combine { inherit (pkgs.texlive) scheme-medium cancel physics siunitx mathtools tcolorbox environ; })
    anki

    gnome-calculator
    neovim
    pwvucontrol
    btop
    macchina
    nix-search-cli

    # GNOME Nautilus file manager (lightweight GTK replacement for Dolphin)
    nautilus
    nautilus-python
    sushi
    file-roller

    inputs.antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
    inputs.antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.google-antigravity-ide
    inputs.antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.google-antigravity-cli
  ];

  programs.obs-studio = {
    enable = true;
    plugins = with pkgs.obs-studio-plugins; [ wlrobs obs-vaapi ];
  };
}
