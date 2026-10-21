{
  config,
  lib,
  pkgs,
  ...
}: let
  app = pkgs.callPackage ../../pkgs/nav {};
  host = "nav.23012006.xyz";
  env = "/var/lib/mcp-gateway/nav.env";
  mapsData = "/srv/data/kowal-lab-maps";
  healthCmd = "--health-cmd=" + builtins.toJSON ["/bin/python3" "-c" "import urllib.request as u;u.urlopen('http://127.0.0.1:8080/healthz',timeout=3)"];
in {
  # reuses the gateway image (python with pyyaml and the CA bundle); the app itself is mounted read-only from the store
  virtualisation.oci-containers.containers.lab-nav = {
    image = "mcp-gateway:local";
    user = "65534:65534";
    autoStart = true;
    cmd = ["/bin/python3" "/nav/server.py"];
    environmentFiles = [env];
    environment = {
      NAV_STATIC = "/nav/static";
      OTP_URL = "http://mcp-otp:8080";
      NOMINATIM_URL = "http://mcp-nominatim:8080";
      GRAPH_MANIFEST = "/maps/graph/manifest.json";
      FEED_CONTACT = "hopkuba@gmail.com";
      SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
    };
    volumes = ["${app}:/nav:ro" "${mapsData}/graph/info:/maps/graph:ro"];
    labels = {
      "traefik.enable" = "true";
      "traefik.docker.network" = "mcp";
      "traefik.http.routers.nav.rule" = "Host(`${host}`)";
      "traefik.http.routers.nav.entrypoints" = "web";
      "traefik.http.routers.nav.middlewares" = "nav-rl";
      "traefik.http.middlewares.nav-rl.ratelimit.average" = "20";
      "traefik.http.middlewares.nav-rl.ratelimit.burst" = "60";
      "traefik.http.services.nav.loadbalancer.server.port" = "8080";
    };
    extraOptions = [
      "--network=mcp"
      "--network=mcp-internal"
      healthCmd
      "--read-only"
      "--tmpfs=/tmp:rw,size=16m,mode=1777"
      "--cap-drop=ALL"
      "--security-opt=no-new-privileges"
      "--memory=192m"
      "--cpus=1"
      "--pids-limit=128"
      "--log-driver=json-file"
      "--log-opt=max-size=5m"
      "--log-opt=max-file=3"
      "--health-interval=60s"
    ];
  };

  systemd.services.podman-lab-nav = {
    requires = ["podman-network-mcp.service" "podman-mcp-gateway.service"];
    after = ["podman-network-mcp.service" "podman-mcp-gateway.service"];
    # no passphrase file yet means no start; the file is created by the owner
    unitConfig.ConditionPathExists = env;
  };
}
