{
  pkgs,
  lib,
  config,
  ...
}: let
  src = pkgs.runCommand "lab-src" {} ''
    mkdir -p $out
    cp ${../scripts/lab.py} $out/lab.py
    cp ${../scripts/guis/lab_bus.py} $out/lab_bus.py
  '';

  # publish is the hot path (volume keys), so it skips Python and goes straight to the Rust client
  lab = pkgs.writeShellApplication {
    name = "lab";
    runtimeInputs = [pkgs.python3 pkgs.systemd config.lab.shell.package];
    text = ''
      export LAB_HUB_HOOKS=${lib.escapeShellArg config.lab.focus.hooksUrl}
      if [ "''${1:-}" = publish ]; then
        shift
        exec lab-publish "$@"
      fi
      exec python3 ${src}/lab.py "$@"
    '';
  };
in {
  options.lab.cli.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "The lab CLI. Add it to runtimeInputs of any wrapper that publishes to the bus.";
  };

  config = {
    lab.cli.package = lab;
    home.packages = [config.lab.cli.package];
  };
}
