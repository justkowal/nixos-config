{ pkgs, lib, osConfig ? { }, ... }:

let
  snapDir = osConfig.lab.snapshots.dir or "/home/.snapshots";

  typelibPath = lib.makeSearchPath "lib/girepository-1.0" [
    pkgs.gtk4
    pkgs.libadwaita
    pkgs.glib.out
    pkgs.graphene
    pkgs.pango.out
    pkgs.gdk-pixbuf
    pkgs.harfbuzz
    pkgs.gobject-introspection
  ];

  timemachine-gui = pkgs.writeShellApplication {
    name = "timemachine-gui";
    runtimeInputs = [ (pkgs.python3.withPackages (ps: [ ps.pygobject3 ])) ];
    text = ''
      export GI_TYPELIB_PATH="${typelibPath}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      exec python3 ${./scripts/guis/timemachine_gui.py} --snapshots ${lib.escapeShellArg snapDir} "$@"
    '';
  };
in
{
  home.packages = [ timemachine-gui ];

  xdg.desktopEntries.timemachine-gui = {
    name = "Time Machine";
    genericName = "Snapshot Browser";
    comment = "Browse, diff and restore files from hourly snapshots";
    exec = "timemachine-gui %f";
    icon = "document-open-recent";
    terminal = false;
    categories = [ "System" "Utility" ];
    settings.StartupWMClass = "lab.justkowal.TimeMachine";
  };

  # KF6 ignores service menus in the user dir unless they are executable
  xdg.dataFile."kio/servicemenus/timemachine.desktop" = {
    executable = true;
    text = ''
      [Desktop Entry]
      Type=Service
      MimeType=inode/directory;
      Actions=browseSnapshots

      [Desktop Action browseSnapshots]
      Name=Browse snapshots
      Icon=document-open-recent
      Exec=${lib.getExe timemachine-gui} %f
    '';
  };
}
