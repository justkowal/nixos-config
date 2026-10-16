{ inputs, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      # Add detector for Gigabyte RX 6700 XT EAGLE 12G (subsystem 1458:2331)
      openrgb = prev.openrgb.overrideAttrs (oldAttrs: {
        patches = (oldAttrs.patches or []) ++ [
          ./patches/openrgb-rx6700xt-eagle.patch
        ];
      });

      millennium =
        let
          origNix = builtins.readFile "${inputs.millennium.outPath}/millennium.nix";
          # upstream's bunDeps hash is stale; bunDeps is a let binding so overrideAttrs can't reach it
          staleHash = "sha256-mAM2qhb0TOzPosejOcG2VegDkbEmY3JF8lkKgDpVjA0=";
          patchedNix =
            if prev.lib.hasInfix staleHash origNix
            then builtins.replaceStrings [ staleHash ] [ "sha256-iPdEl5GH0cXjn1EUdYutqxdMwdRXms+eXCEIwZ3xeLY=" ] origNix
            else throw "millennium: upstream bunDeps hash changed, drop the hash patch in modules/overlays.nix";
        in
        final.callPackage (builtins.toFile "millennium.nix" patchedNix) {
          millennium-src = inputs.millennium.inputs.millennium-src;
        };

      millennium-steam = final.callPackage "${inputs.millennium.outPath}/steam.nix" {
        inherit (final) millennium;
      };
    })
  ];
}
