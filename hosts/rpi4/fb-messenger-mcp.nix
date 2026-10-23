{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.lab.fbMessengerMcp;
  host = "mcp.23012006.xyz";
  dir = "/var/lib/mcp-gateway";
  secrets = "${dir}/secrets.env";
  fbmcpEnv = "${dir}/fbmcp.env";

  # The source context for building the container image on the Pi
  fbmcpCtx = pkgs.runCommand "fb-messenger-mcp-context" {} ''
    mkdir -p $out
    cp -r ${../../pkgs/fb-messenger-mcp}/* $out/
  '';
  tag = builtins.substring 11 8 (builtins.baseNameOf fbmcpCtx);
in {
  options.lab.fbMessengerMcp = {
    enable = lib.mkEnableOption "Facebook Messenger MCP server container";
  };

  config = lib.mkIf cfg.enable {
    # Ensure fbmcp.env exists with safe permissions if not already present
    systemd.services.fb-messenger-mcp-env = {
      description = "Ensure fb-messenger-mcp env file exists";
      wantedBy = ["multi-user.target"];
      before = ["podman-fb-messenger-mcp.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ ! -f ${fbmcpEnv} ]; then
          install -d -m 0750 ${dir}
          touch ${fbmcpEnv}
          chmod 0600 ${fbmcpEnv}
          cat << 'EOF' > ${fbmcpEnv}
# Facebook Messenger Platform API credentials
# Set your page access token (or MESSENGER_PLATFORM_API_API_KEY) and Page ID
# MESSENGER_PLATFORM_API_API_KEY=
# FB_PAGE_ID=
EOF
        fi
      '';
    };

    # Build the fb-messenger-mcp image on the Pi
    systemd.services.fb-messenger-mcp-image = {
      description = "Build the fb-messenger-mcp image";
      wantedBy = ["multi-user.target"];
      before = ["podman-fb-messenger-mcp.service"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      path = [pkgs.podman];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "20min";
      };
      script = "podman image exists fb-messenger-mcp:${tag} || podman build -t fb-messenger-mcp:${tag} ${fbmcpCtx}";
    };

    virtualisation.oci-containers.containers.fb-messenger-mcp = {
      image = "fb-messenger-mcp:${tag}";
      autoStart = true;
      user = "1000:1000";
      environmentFiles = [
        secrets
        fbmcpEnv
      ];
      environment = {
        PORT = "3001";
        NODE_ENV = "production";
      };
      labels = {
        "traefik.enable" = "true";
        "traefik.docker.network" = "mcp";
        # Expose under mcp.23012006.xyz/fbmcp with higher priority than default gateway
        "traefik.http.routers.fbmcp.rule" = "Host(`${host}`) && PathPrefix(`/fbmcp`) || Host(`fbmcp.23012006.xyz`)";
        "traefik.http.routers.fbmcp.entrypoints" = "web";
        "traefik.http.routers.fbmcp.priority" = "100";
        "traefik.http.routers.fbmcp.middlewares" = "fbmcp-rl";
        "traefik.http.middlewares.fbmcp-rl.ratelimit.average" = "10";
        "traefik.http.middlewares.fbmcp-rl.ratelimit.burst" = "30";
        "traefik.http.services.fbmcp.loadbalancer.server.port" = "3001";
      };
      extraOptions = [
        "--network=mcp"
        "--health-cmd=node -e \"fetch('http://127.0.0.1:3001/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""
        "--health-interval=60s"
        "--health-start-period=30s"
        "--health-retries=3"
        "--tmpfs=/tmp:rw,size=16m,mode=1777"
        "--read-only"
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges"
        "--memory=256m"
        "--cpus=1"
        "--pids-limit=128"
        "--log-driver=json-file"
        "--log-opt=max-size=5m"
        "--log-opt=max-file=3"
      ];
    };

    systemd.services.podman-fb-messenger-mcp = {
      requires = ["fb-messenger-mcp-image.service" "fb-messenger-mcp-env.service" "podman-network-mcp.service"];
      after = ["fb-messenger-mcp-image.service" "fb-messenger-mcp-env.service" "podman-network-mcp.service"];
    };
  };
}
