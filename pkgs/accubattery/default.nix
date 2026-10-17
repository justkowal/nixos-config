{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "accubattery";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./Cargo.toml ./Cargo.lock ./src];
  };
  cargoLock.lockFile = ./Cargo.lock;

  meta.mainProgram = "accubattery";
}
