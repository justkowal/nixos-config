{ config, pkgs, ... }:

let
  initAudioWinePrefix = pkgs.writeShellScriptBin "init-audio-wine-prefix" ''
    #!/usr/bin/env bash
    set -e
    export WINEPREFIX="$HOME/.wine-audio"
    export WINEARCH="win64"

    echo "Initializing Wine prefix in $WINEPREFIX..."
    ${pkgs.wineWow64Packages.staging}/bin/wineboot --init

    echo "Installing Windows runtime dependencies..."
    ${pkgs.winetricks}/bin/winetricks -q corefonts vcrun2015 vcrun2018 vcrun2022 d3dcompiler_47

    mkdir -p "$WINEPREFIX/drive_c/Program Files/Common Files/VST3"
    mkdir -p "$WINEPREFIX/drive_c/Program Files/Steinberg/VstPlugins"

    ${pkgs.yabridge}/bin/yabridgectl add "$WINEPREFIX/drive_c/Program Files/Common Files/VST3" || true
    ${pkgs.yabridge}/bin/yabridgectl add "$WINEPREFIX/drive_c/Program Files/Steinberg/VstPlugins" || true
    ${pkgs.yabridge}/bin/yabridgectl sync

    echo "Wine audio prefix initialized. Drop plugins into the above directories and run: yabridgectl sync"
  '';
in
{
  boot.kernelModules = [ "snd-seq-midi" ];

  environment.systemPackages = with pkgs; [
    bitwig-studio
    qpwgraph
    jack2
    vital
    surge-xt
    lsp-plugins
    dragonfly-reverb
    chow-tape-model
    chow-centaur
    decent-sampler
    wineWow64Packages.staging
    winetricks
    yabridge
    initAudioWinePrefix
  ];
}
