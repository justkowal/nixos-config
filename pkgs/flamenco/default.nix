{
  lib,
  fetchgit,
  buildGoModule,
  buildNpmPackage,
  zip,
}:
let
  version = "3.6";
  src = fetchgit {
    url = "https://projects.blender.org/studio/flamenco.git";
    rev = "v${version}";
    hash = "sha256-nyr1DOoEgsjmDZmQSEvQ0yMseCcXrFDRQJeWtj5OyKM=";
  };

  webapp = buildNpmPackage {
    pname = "flamenco-webapp";
    inherit version;
    src = "${src}/web/app";
    npmDepsHash = "sha256-sjGNKU/+4AKxmH55efgCOhO0wzMYXSQGerpTDkzxRvo=";
    postPatch = ''
      cp ${./package-lock.json} package-lock.json
      chmod +w package-lock.json
    '';
    npmBuildScript = "build";
    npmBuildFlags = [
      "--"
      "--outDir"
      "dist"
      "--base=/app/"
    ];
    installPhase = ''
      mkdir -p $out
      cp -r dist/* $out/
    '';
  };
in
buildGoModule {
  pname = "flamenco-manager";
  inherit version src;

  vendorHash = "sha256-0q+wMisKmVZuTp1VdJ7GM1xiHM2FJAF0O6IiuwsK3e4=";
  subPackages = [ "cmd/flamenco-manager" ];

  nativeBuildInputs = [ zip ];

  preBuild = ''
    mkdir -p web/static
    cp -r ${webapp}/* web/static/
    (cd addon && zip -r ../web/static/flamenco-addon.zip flamenco)
  '';

  meta = with lib; {
    description = "Flamenco Manager — render farm coordination for Blender";
    homepage = "https://flamenco.blender.org";
    license = licenses.gpl3Plus;
    mainProgram = "flamenco-manager";
  };
}
