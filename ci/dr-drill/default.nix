# nix build --impure -f ci/dr-drill driver --argstr flakePath "$PWD"
{flakePath ? toString ../..}: let
  flake = builtins.getFlake flakePath;
  pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
in
  pkgs.testers.runNixOSTest {
    name = "rpi4-dr-drill";
    node.specialArgs = {inherit (flake) inputs;};
    nodes.pi = ./vm.nix;
    globalTimeout = 7200;
    testScript = builtins.readFile ./drill.py;
  }
