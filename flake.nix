{
  description = "Modular NixOS configuration with optimized kernel and custom shell/desktop environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
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
  } @ inputs: {
    nixosConfigurations.desktop = nixpkgs.lib.nixosSystem {
      specialArgs = {inherit inputs;};
      modules = [
        { nixpkgs.hostPlatform = "x86_64-linux"; }
        ./hosts/desktop/configuration.nix
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.justkowal = import ./hosts/desktop/home.nix;
        }
      ];
    };
  };
}
