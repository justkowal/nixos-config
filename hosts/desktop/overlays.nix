{ inputs, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      # Fix minizip-ng test failure
      minizip-ng = prev.minizip-ng.overrideAttrs (oldAttrs: {
        doCheck = false;
      });

      millennium = final.callPackage "${inputs.millennium.outPath}/millennium.nix" {
        millennium-src = inputs.millennium.inputs.millennium-src;
      };

      millennium-steam = final.callPackage "${inputs.millennium.outPath}/steam.nix" {
        inherit (final) millennium;
      };
    })
  ];
}
