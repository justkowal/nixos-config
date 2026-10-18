{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "thunderbird-mcp";
  version = "0.2.1";

  src = fetchFromGitHub {
    owner = "mudler";
    repo = "thunderbird-mcp";
    rev = "v${version}";
    hash = "sha256-JXZyh90Kh1zeoAeR/9rdffBmAs4gISSYj7Az1NbAzcw=";
  };

  vendorHash = "sha256-PJ3g5Qsyuuq4WnkdYwV8KtUwvNZixHFRYt2H2n7rodo=";

  # pure go sqlite, the project promises a static cgo-free binary
  env.CGO_ENABLED = 0;

  meta = {
    description = "MCP server exposing a local Thunderbird profile (mail, contacts, calendar)";
    homepage = "https://github.com/mudler/thunderbird-mcp";
    license = lib.licenses.mit;
    mainProgram = "thunderbird-mcp";
  };
}
