{
  lib,
  rustPlatform,
  pkg-config,
  wrapGAppsHook4,
  gtk4,
  libadwaita,
  gtk4-layer-shell,
  glib,
  gst_all_1,
  libgbm,
  libdrm,
}:
rustPlatform.buildRustPackage {
  pname = "labd";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./Cargo.toml ./Cargo.lock ./src ./assets ./protocols];
  };
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [pkg-config wrapGAppsHook4];
  buildInputs = [gtk4 libadwaita gtk4-layer-shell glib gst_all_1.gstreamer gst_all_1.gst-plugins-base gst_all_1.gst-plugins-good gst_all_1.gst-plugins-bad libgbm libdrm];

  # layer-shell has to be loaded before libwayland-client, link order alone is not reliable
  preFixup = ''
    gappsWrapperArgs+=(--prefix LD_PRELOAD : ${gtk4-layer-shell}/lib/libgtk4-layer-shell.so)
    # the palette launches apps with `gio launch`
    gappsWrapperArgs+=(--prefix PATH : ${lib.makeBinPath [glib.bin]})
    # lab-stream encodes through GStreamer's VA-API plugins
    gappsWrapperArgs+=(--prefix GST_PLUGIN_SYSTEM_PATH_1_0 : ${lib.makeSearchPath "lib/gstreamer-1.0" [gst_all_1.gstreamer.out gst_all_1.gst-plugins-base gst_all_1.gst-plugins-bad]})
  '';

  meta.mainProgram = "labd";
}
