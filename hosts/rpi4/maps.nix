{
  config,
  lib,
  pkgs,
  ...
}: let
  data = "/srv/data/kowal-lab-maps";

  # both pinned by the manifest-list digest, so the Pi pulls the arm64 build of exactly what was measured on the desktop
  nominatimImage = "docker.io/mediagis/nominatim@sha256:7923a8e67197fc6d4f4ecb7c0e8bbedffeddcfdf4519596fe946e46a28f5a9f8";
  otpImage = "docker.io/opentripplanner/opentripplanner@sha256:8d54e5c589186707ee365417f2202dc878c451fa3001b8edff07019531100933";

  # internal network only: the osm server reads the database as the read-only role osmro, nothing else gets in without a password
  pgHba = pkgs.writeText "pg_hba.conf" ''
    local all postgres peer
    local all all peer
    host nominatim osmro 0.0.0.0/0 trust
    host all all 127.0.0.1/32 scram-sha-256
    host all all ::1/128 scram-sha-256
    host all all 0.0.0.0/0 md5
  '';

  # measured on the desktop: 800 MB heap with the serial collector serves the pruned graph in about 0.95 GiB
  otpJvm = "-Xmx800m -XX:+UseSerialGC -Xss512k -XX:MaxMetaspaceSize=128m -XX:TieredStopAtLevel=1";

  common = [
    "--network=mcp-internal"
    "--log-driver=json-file"
    "--log-opt=max-size=5m"
    "--log-opt=max-file=3"
    "--health-interval=60s"
    "--health-start-period=120s"
  ];
in {
  # 4 GB behind the zram swap; the disk is slow, so it only catches spikes
  swapDevices = [
    {
      device = "/srv/data/swapfile";
      size = 4096;
      priority = 1;
      options = ["nofail"];
    }
  ];

  systemd.tmpfiles.rules = [
    "d ${data} 0755 root root -"
    "d ${data}/graph 0755 root root -"
    "d ${data}/graph/current 0755 root root -"
    "d ${data}/graph/previous 0755 root root -"
    "d ${data}/graph/upload 0755 root root -"
    "d ${data}/adapters 0755 root root -"
    "d ${data}/osm 0755 root root -"
  ];

  virtualisation.oci-containers.containers = {
    mcp-nominatim = {
      image = nominatimImage;
      autoStart = true;
      environment = {
        # the start script insists on one of these even when the import already exists
        PBF_PATH = "/nominatim/unused.osm.pbf";
        FREEZE = "true";
        NOMINATIM_PASSWORD = "x";
        GUNICORN_WORKERS = "2";
        # the image defaults assume a 32 GB import machine
        POSTGRES_SHARED_BUFFERS = "256MB";
        POSTGRES_MAINTENANCE_WORK_MEM = "64MB";
        POSTGRES_AUTOVACUUM_WORK_MEM = "64MB";
        POSTGRES_WORK_MEM = "16MB";
        POSTGRES_EFFECTIVE_CACHE_SIZE = "1GB";
      };
      volumes = [
        "${data}/nominatim:/var/lib/postgresql/16/main:rw"
        "${pgHba}:/etc/postgresql/16/main/pg_hba.conf:ro"
      ];
      # the upstream image drives postgres and gunicorn through sudo, so no-new-privileges cannot be set here
      extraOptions =
        common
        ++ [
          "--memory=1000m"
          "--cpus=2"
          "--pids-limit=256"
          "--shm-size=256m"
          "--cap-drop=ALL"
          "--cap-add=CHOWN"
          "--cap-add=DAC_OVERRIDE"
          "--cap-add=FOWNER"
          "--cap-add=SETUID"
          "--cap-add=SETGID"
          "--cap-add=KILL"
          "--cap-add=AUDIT_WRITE"
          ("--health-cmd=" + builtins.toJSON ["curl" "-fsS" "http://127.0.0.1:8080/status"])
        ];
    };

    mcp-otp = {
      image = otpImage;
      autoStart = true;
      cmd = ["--load" "--serve"];
      user = "65534:65534";
      environment.JAVA_OPTS = otpJvm;
      volumes = ["${data}/graph/current:/var/opentripplanner:ro"];
      extraOptions =
        common
        ++ [
          "--read-only"
          "--tmpfs=/tmp:rw,size=64m,mode=1777"
          "--memory=1200m"
          "--cpus=2"
          "--pids-limit=128"
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
          ("--health-cmd=" + builtins.toJSON ["bash" "-c" "exec 3<>/dev/tcp/127.0.0.1/8080; printf 'GET /otp/actuators/health HTTP/1.0\\r\\n\\r\\n' >&3; head -1 <&3 | grep -q 200"])
        ];
    };
  };

  # neither starts until its data is on the disk, so a missing or empty disk never makes them loop
  systemd.services.podman-mcp-nominatim = {
    unitConfig.ConditionPathExists = "${data}/nominatim/import-finished";
    requires = ["podman-network-mcp.service"];
    after = ["podman-network-mcp.service" "srv-data.mount"];
  };
  systemd.services.podman-mcp-otp = {
    unitConfig.ConditionPathExists = "${data}/graph/current/graph.obj";
    requires = ["podman-network-mcp.service"];
    after = ["podman-network-mcp.service" "srv-data.mount"];
  };
}
