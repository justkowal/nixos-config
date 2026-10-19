{
  lib,
  stdenvNoCC,
  python3,
}:
stdenvNoCC.mkDerivation {
  pname = "agh-mcp";
  version = "0.2.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./agh_mcp.py ./test_agh_mcp.py];
  };

  buildInputs = [python3];
  doCheck = true;
  checkPhase = "python3 -m unittest -v test_agh_mcp";

  installPhase = ''
    install -Dm755 agh_mcp.py $out/bin/agh-mcp
    patchShebangs $out/bin/agh-mcp
  '';

  meta = {
    description = "Read-only MCP server for UPeL (Moodle) and the AGH course syllabi";
    mainProgram = "agh-mcp";
  };
}
