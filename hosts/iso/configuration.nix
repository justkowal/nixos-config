{
  config,
  pkgs,
  modulesPath,
  lib,
  inputs,
  ...
}: {
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
  ];

  # Installer packages: disko for declarative partitioning, gum for TUI wizard
  environment.systemPackages = with pkgs; [
    disko
    gum
    bcachefs-tools
    git
    nh
    parted
    e2fsprogs
    dosfstools
  ];

  # Enable SSH on installer ISO for remote installations
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  # Auto-start alias and banner for installer
  environment.interactiveShellInit = ''
    alias install-tui="bash /etc/nixos/hosts/iso/install-tui.sh"
    echo ""
    echo "=================================================================="
    echo "          Custom NixOS Modular Multi-Host TUI Installer           "
    echo "=================================================================="
    echo " Run 'install-tui' to start the interactive installation wizard.   "
    echo "=================================================================="
    echo ""
  '';

  nix.settings.experimental-features = ["nix-command" "flakes"];
  nixpkgs.hostPlatform = "x86_64-linux";
}
