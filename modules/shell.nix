{ pkgs, ... }:

{
  # Nushell and bash available system-wide
  environment.shells = with pkgs; [ nushell bashInteractive ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  environment.systemPackages = with pkgs; [
    uutils-coreutils-noprefix
  ];

  environment.interactiveShellInit = ''
    alias fallback-bash="exec ${pkgs.bashInteractive}/bin/bash"
  '';
}
