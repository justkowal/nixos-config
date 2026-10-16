{pkgs, ...}: let
  src = pkgs.runCommand "lab-src" {} ''
    mkdir -p $out
    cp ${../scripts/lab.py} $out/lab.py
    cp ${../scripts/guis/lab_bus.py} $out/lab_bus.py
  '';

  lab = pkgs.writeShellApplication {
    name = "lab";
    runtimeInputs = [pkgs.python3 pkgs.systemd];
    text = ''exec python3 ${src}/lab.py "$@"'';
  };
in {
  home.packages = [lab];
}
