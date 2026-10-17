{
  lib,
  rustPlatform,
  pkg-config,
  wrapGAppsHook4,
  gtk4,
  libadwaita,
  glib,
  pango,
  cairo,
}:
rustPlatform.buildRustPackage {
  pname = "accubattery";
  version = "0.2.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./Cargo.toml ./Cargo.lock ./src];
  };
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [pkg-config wrapGAppsHook4];
  buildInputs = [gtk4 libadwaita glib pango cairo];

  meta.mainProgram = "accubattery";
}
