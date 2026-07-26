{
  description = "Modular NixOS configuration across Desktop, VM, and Laptop hosts with unified Home Manager userland experience";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
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
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    ...
  } @ inputs: let
    # Shared Home Manager Userland Module for consistent desktop & shell experience across all machines
    sharedHomeManagerModule = {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.justkowal = import ./hosts/desktop/home.nix;
    };
  in {
    nixosConfigurations = rec {
      # 1. Bare-metal Desktop Host Target (AMD Ryzen + Radeon RX 6700 XT + Custom LTO Kernel)
      desktop = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          ./hosts/desktop/configuration.nix
          home-manager.nixosModules.home-manager
          sharedHomeManagerModule
        ];
      };
      nixos-desktop = desktop;

      # 2. Virtual Machine Host Target (QEMU/KVM/VirtualBox Integration + Shared Userland)
      vm = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          ./hosts/vm/configuration.nix
          home-manager.nixosModules.home-manager
          sharedHomeManagerModule
        ];
      };

      # 3. Laptop Host Target (TLP Battery Management + Touchpad + Shared Userland)
      laptop = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          ./hosts/laptop/configuration.nix
          home-manager.nixosModules.home-manager
          sharedHomeManagerModule
        ];
      };

      # 4. Custom Bootable USB ISO Installer Target (with interactive TUI wizard & partitioning)
      iso = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          ./hosts/iso/configuration.nix
        ];
      };
    };
  };
}
