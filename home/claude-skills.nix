{
  config,
  lib,
  ...
}: let
  dir = ./claude/skills;
in {
  # one symlink per skill, so ~/.claude/skills stays a real dir the app can still write to.
  home.file = lib.mapAttrs' (name: _: lib.nameValuePair ".claude/skills/${name}" {source = dir + "/${name}";}) (builtins.readDir dir);
}
