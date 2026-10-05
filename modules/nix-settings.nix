{ pkgs, ... }:

{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    max-jobs = "auto";
    cores = 0;
    auto-optimise-store = false;
    connect-timeout = 3;
    fallback = true;
    system-features = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    substituters = [
      "https://cache.lab?priority=40"
      "https://cache.nixos.org"
      "https://hyprland.cachix.org"
      "https://nix-community.cachix.org"
    ];
    trusted-substituters = [
      "https://cache.lab"
    ];
    trusted-public-keys = [
      "cache.lab-1:c9FqhvtNtZhA0JsLN4+tDAJBcwnvYOcD5YAuHzA5eoA="
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    trusted-users = [ "root" "justkowal" "@wheel" ];
    builders-use-substitutes = true;
  };

  nix.distributedBuilds = true;

  nixpkgs.config.allowUnfree = true;

  programs.nh = {
    enable = true;
    clean.enable = true;
    clean.extraArgs = "--keep 5";
    flake = "/etc/nixos";
  };

  # nh handles GC dynamically
  nix.gc.automatic = false;

  programs.nix-ld.enable = true;

  environment.systemPackages = with pkgs; [
    nix-output-monitor # `nom` real-time interactive build graph & progress tree
    nix-tree           # interactive TUI package dependency tree browser
  ];
}
