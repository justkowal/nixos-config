{
  lib,
  rustPlatform,
  pkg-config,
  wrapGAppsHook4,
  gtk4,
  libadwaita,
  gtk4-layer-shell,
  glib,
}:
rustPlatform.buildRustPackage {
  pname = "labd";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./Cargo.toml ./Cargo.lock ./src ./assets];
  };
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [pkg-config wrapGAppsHook4];
  buildInputs = [gtk4 libadwaita gtk4-layer-shell glib];

  # layer-shell has to be loaded before libwayland-client, link order alone is not reliable
  preFixup = ''
    gappsWrapperArgs+=(--prefix LD_PRELOAD : ${gtk4-layer-shell}/lib/libgtk4-layer-shell.so)
    # the palette launches apps with `gio launch`
    gappsWrapperArgs+=(--prefix PATH : ${lib.makeBinPath [glib.bin]})
  '';

  meta.mainProgram = "labd";
}
