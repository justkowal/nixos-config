{
  config,
  lib,
  pkgs,
  ...
}: {
  options.lab.greeter.command = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    description = "The tuigreet command line for greetd, shared by the laptop and the desktop.";
  };

  config.lab.greeter.command = lib.concatStringsSep " " [
    "${pkgs.tuigreet}/bin/tuigreet"
    "--greeting 'KOWAL LAB'"
    "--time --time-format '%H:%M  %A, %-d %B'"
    "--remember --remember-session"
    "--asterisks --asterisks-char '•'"
    "--width 56 --window-padding 2 --container-padding 2 --prompt-padding 1"
    # a text console has no pixel fonts and no wallpaper colours, so ANSI names only (lightred is the
    # closest to the rose accent); an unknown key or colour is ignored by tuigreet, never an error
    "--theme 'text=white;container=black;border=darkgray;greet=lightred;prompt=lightred;input=white;time=gray;action=darkgray;button=lightred'"
    "--cmd Hyprland"
  ];
}
