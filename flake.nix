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
    user = "justkowal";

    # Shared Home Manager Userland Module
    sharedHomeManagerModule = {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.${user} = import ./hosts/desktop/home.nix;
    };
  in {
    nixosConfigurations = {
      desktop = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          ./hosts/desktop/configuration.nix
          home-manager.nixosModules.home-manager
          sharedHomeManagerModule
        ];
      };

      vm = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          ./hosts/vm/configuration.nix
          home-manager.nixosModules.home-manager
          sharedHomeManagerModule
        ];
      };

      laptop = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          ./hosts/laptop/configuration.nix
          home-manager.nixosModules.home-manager
          sharedHomeManagerModule
        ];
      };

      iso = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          ./hosts/iso/configuration.nix
        ];
      };
    };

    # Alias for desktop target
    nixosConfigurations.nixos-desktop = self.nixosConfigurations.desktop;
  };
}
