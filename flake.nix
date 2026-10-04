{
  description = "Modular NixOS configuration across Desktop, VM, Laptop, and RPi4 hosts with unified Home Manager userland experience and scale-to-zero serverless homelab architecture";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # Pinned kernel input: isolated from general package updates so custom kernel never rebuilds unexpectedly
    nixpkgs-kernel.url = "github:nixos/nixpkgs/5880666fd9eb563038431edb35c2d0aa595884e6";
    millennium = {
      url = "github:SteamClientHomebrew/Millennium?dir=packages/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    antigravity-nix = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    ...
  } @ inputs: let
    user = "justkowal";

    # Shared Home Manager Userland Module
    makeHomeManagerModule = isLaptop: {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = {
        laptop = isLaptop;
      };
      home-manager.users.${user} = import ./hosts/desktop/home.nix;
    };
  in {
    nixosConfigurations = {
      desktop = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          {nixpkgs.hostPlatform = "x86_64-linux";}
          inputs.sops-nix.nixosModules.sops
          ./hosts/desktop/configuration.nix
          home-manager.nixosModules.home-manager
          (makeHomeManagerModule false)
        ];
      };

      vm = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          {nixpkgs.hostPlatform = "x86_64-linux";}
          ./hosts/vm/configuration.nix
          home-manager.nixosModules.home-manager
          (makeHomeManagerModule false)
        ];
      };

      laptop = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          {nixpkgs.hostPlatform = "x86_64-linux";}
          inputs.lanzaboote.nixosModules.lanzaboote
          inputs.sops-nix.nixosModules.sops
          ./hosts/laptop/configuration.nix
          home-manager.nixosModules.home-manager
          (makeHomeManagerModule true)
        ];
      };

      iso = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs self;};
        modules = [
          {nixpkgs.hostPlatform = "x86_64-linux";}
          ./hosts/iso/configuration.nix
        ];
      };

      # ── Raspberry Pi 4 (Orchestrator) ────────────────────────────────
      # Build bootable SD image:
      #   nix build .#nixosConfigurations.rpi4.config.system.build.sdImage
      rpi4 = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          {nixpkgs.hostPlatform = "aarch64-linux";}
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          inputs.sops-nix.nixosModules.sops
          ./hosts/rpi4/configuration.nix
        ];
      };
    };

    # Hostname aliases
    nixosConfigurations.nixos-desktop = self.nixosConfigurations.desktop;
    nixosConfigurations.thinkpad-t14s-gen1-amd = self.nixosConfigurations.laptop;
  };
}
