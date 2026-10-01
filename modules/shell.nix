{ pkgs, ... }:

{
  # Nushell and bash available system-wide
  environment.shells = with pkgs; [ nushell bashInteractive ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    silent = true;
  };

  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      zlib
      stdenv.cc.cc
      openssl
      icu
      fuse3
      glibc
      libx11
      libxcursor
      libxrandr
      libxi
      libglvnd
    ];
  };

  environment.systemPackages = with pkgs; [
    uutils-coreutils-noprefix
  ];

  environment.sessionVariables = {
    PLAYWRIGHT_DRIVER_DOWNLOAD_HOST = "";
    PLAYWRIGHT_DRIVER_PATH = "${pkgs.playwright-driver}";
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  };

  environment.interactiveShellInit = ''
    alias fallback-bash="exec ${pkgs.bashInteractive}/bin/bash"
    alias discord="vesktop"
  '';
}
