{
  stdenvNoCC,
  fetchurl,
}: let
  # pinned and served from our own origin so the page loads no third-party script
  maplibre = fetchurl {
    url = "https://registry.npmjs.org/maplibre-gl/-/maplibre-gl-5.24.0.tgz";
    hash = "sha256-XL+DwyjJ05yyTj8s78m0B9ad0QS6C0HoTAv7sxxE4oM=";
  };
in
  stdenvNoCC.mkDerivation {
    name = "kowal-nav";
    src = ./.;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/static/vendor $TMPDIR/ml
      cp server.py hours.py places.py $out/
      cp -r static/. $out/static/
      rm -rf $out/static/vendor && mkdir $out/static/vendor
      tar -xzf ${maplibre} -C $TMPDIR/ml
      cp $TMPDIR/ml/package/dist/maplibre-gl.js $TMPDIR/ml/package/dist/maplibre-gl.css $out/static/vendor/
    '';
  }
