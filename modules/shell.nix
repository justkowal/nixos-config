{ config, pkgs, ... }:

{
  # Configure Nushell as the default interactive shell for justkowal
  users.users.justkowal.shell = pkgs.nushell;

  # Make shells available in the system
  environment.shells = with pkgs; [
    nushell
    bashInteractive
  ];

  # Starship prompt integration (automatic for bash, zsh, fish, nushell)
  programs.starship = {
    enable = true;
  };

  # Enable direnv and nix-direnv (for fast, clean developer shells)
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # System-wide shell packages
  environment.systemPackages = with pkgs; [
    # Rust coreutils (noprefix creates tools like ls, cp, mv instead of uuls, uucp, etc.)
    uutils-coreutils-noprefix
  ];

  # Ensure user can easily drop back to bash by setting an alias or fallback
  environment.interactiveShellInit = ''
    alias fallback-bash="exec ${pkgs.bashInteractive}/bin/bash"
  '';
}
