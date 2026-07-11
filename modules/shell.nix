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
    # Sleek Catppuccin Mocha preset
    settings = {
      add_newline = true;
      format = "$directory$git_branch$git_status$character";
      palette = "catppuccin_mocha";

      directory = {
        style = "bold lavender";
      };

      character = {
        success_symbol = "[❯](bold green)";
        error_symbol = "[❯](bold red)";
      };

      git_branch = {
        style = "bold mauve";
      };

      git_status = {
        style = "bold red";
      };

      palettes.catppuccin_mocha = {
        rosewater = "#f5e0dc";
        flamingo = "#f2cdcd";
        pink = "#f5c2e7";
        mauve = "#cba6f7";
        red = "#f38ba8";
        maroon = "#eba0ac";
        peach = "#fab387";
        yellow = "#f9e2af";
        green = "#a6e3a1";
        teal = "#94e2d5";
        sky = "#89dceb";
        sapphire = "#74c7ec";
        blue = "#89b4fa";
        lavender = "#b4befe";
        text = "#cdd6f4";
        subtext1 = "#bac2de";
        subtext0 = "#a6adc8";
        overlay2 = "#585b70";
        overlay1 = "#7f849c";
        overlay0 = "#6c7086";
        surface2 = "#585b70";
        surface1 = "#45475a";
        surface0 = "#313244";
        base = "#1e1e2e";
        mantle = "#181825";
        crust = "#11111b";
      };
    };
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
    # Nushell shell
    nushell
    # Prompt
    starship
    # Developer environment manager
    direnv
  ];

  # Ensure user can easily drop back to bash by setting an alias or fallback
  environment.interactiveShellInit = ''
    alias fallback-bash="exec ${pkgs.bashInteractive}/bin/bash"
  '';
}
