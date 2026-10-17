{
  lib,
  rustPlatform,
  pkg-config,
  wrapGAppsHook4,
  makeWrapper,
  gtk4,
  libadwaita,
  glib,
  pango,
  cairo,
  python3,
  gobject-introspection,
  evolution-data-server,
  libical,
  libsoup_3,
  json-glib,
}: let
  typelibs = lib.makeSearchPath "lib/girepository-1.0" [
    evolution-data-server
    libical
    glib.out
    gobject-introspection
    libsoup_3
    json-glib
  ];
in
  rustPlatform.buildRustPackage {
    pname = "accubattery";
    version = "0.3.0";

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [./Cargo.toml ./Cargo.lock ./src ./tests];
    };
    cargoLock.lockFile = ./Cargo.lock;

    nativeBuildInputs = [pkg-config wrapGAppsHook4 makeWrapper];
    buildInputs = [gtk4 libadwaita glib pango cairo];

    # the daemon asks this for upcoming calendar events, same calendars as the travel check
    postInstall = ''
      makeWrapper ${python3.withPackages (ps: [ps.pygobject3])}/bin/python3 $out/bin/accubattery-events \
        --add-flags ${./scripts/events.py} \
        --set GI_TYPELIB_PATH ${typelibs}
    '';

    meta.mainProgram = "accubattery";
  }
