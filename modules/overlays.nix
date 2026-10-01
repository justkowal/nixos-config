{ inputs, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      # Fix minizip-ng test failure
      minizip-ng = prev.minizip-ng.overrideAttrs (oldAttrs: {
        doCheck = false;
      });

      # Add detector for Gigabyte RX 6700 XT EAGLE 12G (subsystem 1458:2331)
      openrgb = prev.openrgb.overrideAttrs (oldAttrs: {
        patches = (oldAttrs.patches or []) ++ [
          ./patches/openrgb-rx6700xt-eagle.patch
        ];
      });

      millennium =
        let
          origNix = builtins.readFile "${inputs.millennium.outPath}/millennium.nix";
          patchedNix = builtins.replaceStrings
            [ "sha256-mAM2qhb0TOzPosejOcG2VegDkbEmY3JF8lkKgDpVjA0=" ]
            [ "sha256-iPdEl5GH0cXjn1EUdYutqxdMwdRXms+eXCEIwZ3xeLY=" ]
            origNix;
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
