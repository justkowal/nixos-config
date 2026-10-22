{
  config,
  lib,
  ...
}: let
  dir = ./claude/skills;
  skillDirs = lib.filterAttrs (name: type: type == "directory") (builtins.readDir dir);
in {
  # one symlink per skill, so ~/.claude/skills and ~/.gemini/config/skills stay real dirs the apps can still write to.
  home.file =
    (lib.mapAttrs' (name: _: lib.nameValuePair ".claude/skills/${name}" {source = dir + "/${name}";}) (builtins.readDir dir))
    // (lib.mapAttrs' (name: _: lib.nameValuePair ".gemini/config/skills/${name}" {source = dir + "/${name}";}) skillDirs);
}
