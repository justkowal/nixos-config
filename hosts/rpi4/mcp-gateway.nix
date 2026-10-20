{
  config,
  lib,
  pkgs,
  ...
}: let
  app = pkgs.callPackage ../../pkgs/mcp-gateway {};
  py = "${pkgs.python3}/bin/python3";
  pyYaml = pkgs.python3.withPackages (p: [p.pyyaml]);
  host = "mcp.23012006.xyz";
  dir = "/var/lib/mcp-gateway";
  secrets = "${dir}/secrets.env";
  internal = "${dir}/internal.env";
  vaultDir = "/home/justkowal/Sync/Notes/Everything";
  garminDir = "/var/lib/mcp-garmin";
  garminVersion = "0.3.19";

  # garmin builds from a hash-pinned pip lock; the tag carries the context hash so edits rebuild it
  garminCtx = pkgs.runCommand "mcp-garmin-context" {} ''
    mkdir -p $out/app
    cp ${./../../pkgs/mcp-gateway/garmin/Containerfile} $out/Containerfile
    cp ${./../../pkgs/mcp-gateway/garmin/requirements.txt} $out/requirements.txt
    for f in gateway stdio_mcp garmin_mcp garmin_login; do cp ${app}/app/$f.py $out/app/; done
  '';
  garminTag = "${garminVersion}-${builtins.substring 11 8 (builtins.baseNameOf garminCtx)}";

  children = [
    {
      name = "agh";
      cmd = [py "/app/agh_mcp.py"];
      env = ["UPEL_TOKEN" "AGH_SYLLABUS_YEAR" "AGH_SYLLABUS_FORM" "AGH_SYLLABUS_LEVEL" "AGH_SYLLABUS_FACULTY" "AGH_SYLLABUS_MAJOR"];
    }
    {
      name = "fleet";
      cmd = [py "/app/fleet_mcp.py"];
      env = ["FLEET_HOSTS" "FLEET_WAKE_URL" "FLEET_SSH_KEY_B64"];
    }
    {
      name = "mail";
      cmd = [py "/app/mail_mcp.py"];
      env = ["MAIL_ADDRESS" "MAIL_PASSWORD" "MAIL_IMAP_HOST" "MAIL_SMTP_HOST" "MAIL_SEND_LIMIT" "MAIL_STATE"];
    }
    {
      # hidden until policy "classes".garmin is set; health data, so values never reach the log
      name = "garmin";
      url = "http://mcp-garmin:8080/mcp";
      token_env = "INTERNAL_TOKEN";
      classes = [];
      timeout = 150;
      log = ["cdate" "startdate" "enddate" "activity_id" "workout_id" "limit"];
    }
    {
      name = "everything";
      url = "http://mcp-vault:8080/mcp";
      token_env = "INTERNAL_TOKEN";
      log = ["path" "paths" "new_path" "folder"];
    }
  ];

  mkImage = {name, paths, env ? []}:
    pkgs.dockerTools.buildImage {
      inherit name;
      tag = "local";
      copyToRoot = pkgs.buildEnv {
        name = "${name}-root";
        paths = paths ++ [pkgs.cacert pkgs.dockerTools.fakeNss app];
        pathsToLink = ["/bin" "/app" "/etc"];
      };
      config = {
        Cmd = ["/bin/python3" "/app/gateway.py"];
        WorkingDir = "/app";
        User = "nobody";
        Env = ["PYTHONPATH=/app" "PYTHONDONTWRITEBYTECODE=1"] ++ env;
      };
    };

  hardening = mem: [
    "--read-only"
    "--tmpfs=/tmp:rw,size=16m,mode=1777"
    "--cap-drop=ALL"
    "--security-opt=no-new-privileges"
    "--memory=${mem}"
    "--cpus=1"
    "--pids-limit=128"
    "--log-driver=json-file"
    "--log-opt=max-size=5m"
    "--log-opt=max-file=3"
    "--health-interval=60s"
  ];
  # exec form: the nix-built images have no /bin/sh
  healthCmd = "--health-cmd=" + builtins.toJSON ["/bin/python3" "-c" "import urllib.request as u;u.urlopen('http://127.0.0.1:8080/healthz',timeout=3)"];
in {
  systemd.services.podman-network-mcp = {
    description = "Podman networks for the MCP gateway";
    wantedBy = ["multi-user.target"];
    before = ["podman-mcp-gateway.service" "podman-mcp-garmin.service" "podman-mcp-vault.service"];
    path = [pkgs.podman];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # mcp-internal has no route out: the vault container cannot reach anything but the gateway
    script = ''
      podman network exists mcp || podman network create --interface-name mcp0 mcp
      podman network exists mcp-internal || podman network create --internal --interface-name mcp1 mcp-internal
    '';
  };

  # shared secret between the gateway and its two inner servers, generated once
  systemd.services.mcp-internal-token = {
    wantedBy = ["multi-user.target"];
    before = ["podman-mcp-gateway.service" "podman-mcp-garmin.service" "podman-mcp-vault.service"];
    serviceConfig.Type = "oneshot";
    script = ''
      [ -s ${internal} ] || { umask 077; echo "INTERNAL_TOKEN=$(${pkgs.openssl}/bin/openssl rand -hex 32)" > ${internal}; }
    '';
  };

  # garmin: pip-built image, rebuilt only when its context changes
  systemd.services.mcp-garmin-image = {
    description = "Build the mcp-garmin image";
    wantedBy = ["multi-user.target"];
    before = ["podman-mcp-garmin.service"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    path = [pkgs.podman];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "20min";
    };
    script = "podman image exists mcp-garmin:${garminTag} || podman build -t mcp-garmin:${garminTag} ${garminCtx}";
  };

  virtualisation.oci-containers.containers = {
    mcp-gateway = {
      imageFile = mkImage {
        name = "mcp-gateway";
        paths = [pkgs.python3 pkgs.openssh];
      };
      image = "mcp-gateway:local";
      user = "65534:65534";
      autoStart = true;
      environmentFiles = [secrets internal];
      environment = {
        GATEWAY_CHILDREN = builtins.toJSON children;
        MCP_POLICY = "/policy/tools.json";
        CATALOG_FILE = "/state/catalog.json";
        MAIL_STATE = "/state/sends.json";
        MAIL_SEND_LIMIT = "20";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        AGH_SYLLABUS_YEAR = "21";
        AGH_SYLLABUS_FORM = "1";
        AGH_SYLLABUS_LEVEL = "4";
        AGH_SYLLABUS_FACULTY = "17";
        AGH_SYLLABUS_MAJOR = "236";
        FLEET_WAKE_URL = "http://host.containers.internal:9100/hooks";
        FLEET_HOSTS = builtins.toJSON {
          desktop = {ip = "100.109.222.110"; wake = "wake-wol";};
          laptop = {ip = "100.69.154.81";};
        };
      };
      volumes = [
        "${dir}/policy:/policy:ro"
        "${dir}/state:/state:rw"
      ];
      labels = {
        "traefik.enable" = "true";
        "traefik.docker.network" = "mcp";
        "traefik.http.routers.mcp.rule" = "Host(`${host}`)";
        "traefik.http.routers.mcp.entrypoints" = "web";
        "traefik.http.routers.mcp.middlewares" = "mcp-rl";
        "traefik.http.middlewares.mcp-rl.ratelimit.average" = "10";
        "traefik.http.middlewares.mcp-rl.ratelimit.burst" = "30";
        "traefik.http.services.mcp.loadbalancer.server.port" = "8080";
      };
      extraOptions = ["--network=mcp" "--network=mcp-internal" healthCmd] ++ hardening "256m";
    };

    mcp-garmin = {
      image = "mcp-garmin:${garminTag}";
      user = "10001:10001";
      autoStart = true;
      environmentFiles = [internal];
      environment = {
        GATEWAY_TOKEN_ENV = "INTERNAL_TOKEN";
        GATEWAY_PASSTHRU = "1";
        HEALTH_FILE = "/tmp/garmin_status.json";
        GATEWAY_CHILDREN = builtins.toJSON [
          {
            name = "garmin";
            cmd = ["python" "/app/garmin_mcp.py"];
            env = ["GARMINTOKENS" "GARMIN_CACHE_SECONDS" "GARMIN_SMOKE_HOURS" "MCP_POLICY" "GARMIN_OUTPUT_DIR" "GARMIN_UPLOAD_DIR"];
            timeout = 140;
          }
        ];
        GARMIN_CACHE_SECONDS = "300";
        GARMIN_SMOKE_HOURS = "24";
        MCP_POLICY = "/policy/tools.json";
      };
      volumes = [
        "${garminDir}/tokens:/garmin/tokens:rw"
        "${garminDir}/output:/output:rw"
        "${garminDir}/upload:/upload:ro"
        "${dir}/policy:/policy:ro"
      ];
      extraOptions = ["--network=mcp" "--health-cmd=python -c \"import urllib.request as u;u.urlopen('http://127.0.0.1:8080/healthz',timeout=3)\""] ++ hardening "384m";
    };

    mcp-vault = {
      imageFile = mkImage {
        name = "mcp-vault";
        paths = [pyYaml];
      };
      image = "mcp-vault:local";
      user = "1000:100";
      autoStart = true;
      environmentFiles = [internal];
      environment = {
        GATEWAY_TOKEN_ENV = "INTERNAL_TOKEN";
        GATEWAY_PASSTHRU = "1";
        HEALTH_FILE = "/tmp/vault_status.json";
        GATEWAY_CHILDREN = builtins.toJSON [
          {
            name = "everything";
            cmd = ["/bin/python3" "/app/vault_mcp.py"];
            env = ["VAULT_DIR" "VAULT_WRITABLE" "VAULT_MAX_NOTE_BYTES" "VAULT_MAX_MULTI"];
          }
        ];
        VAULT_DIR = "/vault";
        # narrow mode: comma-separated folders, for example "ai,inbox". empty means the whole vault
        VAULT_WRITABLE = "";
      };
      volumes = ["${vaultDir}:/vault:rw"];
      extraOptions = ["--network=mcp-internal" healthCmd] ++ hardening "128m";
    };
  };

  # none of them start until their data exists, so a deploy never exposes a half-configured server
  systemd.services.podman-mcp-gateway = {
    unitConfig.ConditionFileNotEmpty = secrets;
    requires = ["podman-network-mcp.service" "mcp-internal-token.service"];
    after = ["podman-network-mcp.service" "mcp-internal-token.service"];
  };
  systemd.services.podman-mcp-garmin = {
    requires = ["podman-network-mcp.service" "mcp-internal-token.service" "mcp-garmin-image.service"];
    after = ["podman-network-mcp.service" "mcp-internal-token.service" "mcp-garmin-image.service"];
  };
  systemd.services.podman-mcp-vault = {
    unitConfig.ConditionPathExists = "${vaultDir}/.stfolder";
    requires = ["podman-network-mcp.service" "mcp-internal-token.service"];
    after = ["podman-network-mcp.service" "mcp-internal-token.service"];
  };

  networking.firewall.interfaces.mcp0.allowedTCPPorts = [9100];

  systemd.tmpfiles.rules = [
    "d ${dir} 0750 root root -"
    "d ${dir}/policy 0755 root root -"
    "f ${dir}/policy/tools.json 0644 root root - {\"disabled\":[],\"enable\":[],\"classes\":{\"garmin\":[]}}"
    "d ${dir}/state 0700 65534 65534 -"
    "f ${secrets} 0600 root root -"
    "d ${garminDir} 0750 root root -"
    "d ${garminDir}/tokens 0700 10001 10001 -"
    "d ${garminDir}/output 0700 10001 10001 -"
    "d ${garminDir}/upload 0750 10001 10001 -"
  ];
}
