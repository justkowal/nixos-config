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

  # public halves of the two keys that live on the desktop; each can do exactly one thing on this Pi
  pushKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICrFdQ1fwh/LchoaYQCDAGVOs1NzX6XxApMWx+bxzfgG maps_push@nixos-desktop";
  pullKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL8AqKUWoQ7lPLJVQddb6EbvGlKz9AyiIKCi1aHzNZV8 maps_pull@nixos-desktop";
  from = "100.109.222.110,192.168.1.0/24";
  stateDir = "/var/lib/mcp-gateway/state";

  graphWatch = pkgs.writeShellApplication {
    name = "graph-watch";
    runtimeInputs = with pkgs; [jq curl podman coreutils findutils gawk gnugrep systemd];
    text = builtins.readFile ./scripts/graph-watch.sh;
  };

  common = [
    "--network=mcp-internal"
    "--log-driver=json-file"
    "--log-opt=max-size=5m"
    "--log-opt=max-file=3"
    "--health-interval=60s"
    "--health-start-period=120s"
  ];
in {
  # desktop push key: write-only into graph/upload, no shell, no forwarding. desktop pull key: read-only on the export folder.
  users.groups.maps-push = {};
  users.groups.maps-pull = {};
  users.users.maps-push = {
    isSystemUser = true;
    group = "maps-push";
    shell = pkgs.bash;
    home = "/var/empty";
    openssh.authorizedKeys.keys = [''restrict,from="${from}",command="${pkgs.rrsync}/bin/rrsync -wo ${data}/graph/upload" ${pushKey}''];
  };
  users.users.maps-pull = {
    isSystemUser = true;
    group = "maps-pull";
    shell = pkgs.bash;
    home = "/var/empty";
    openssh.authorizedKeys.keys = [''restrict,from="${from}",command="${pkgs.rrsync}/bin/rrsync -ro ${data}/export" ${pullKey}''];
  };
  environment.systemPackages = [pkgs.rsync];

  # the registry and local feed files are copied into a folder the pull key can read, so it never touches the real state directory
  systemd.services.maps-export-sync = {
    description = "Copy the feed registry into the export folder";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "maps-export-sync" ''
        set -eu
        [ -f ${stateDir}/feeds.yaml ] && ${pkgs.rsync}/bin/rsync -a --chown=maps-pull:maps-pull ${stateDir}/feeds.yaml ${data}/export/
        [ -d ${stateDir}/feeds-local ] && ${pkgs.rsync}/bin/rsync -a --delete --chown=maps-pull:maps-pull ${stateDir}/feeds-local/ ${data}/export/feeds-local/
        exit 0
      '';
    };
  };
  systemd.timers.maps-export-sync = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
    };
  };

  # 4 GB behind the zram swap; the disk is slow, so it only catches spikes
  swapDevices = [
    {
      device = "/srv/data/swapfile";
      size = 4096;
      priority = 1;
      options = ["nofail"];
    }
  ];

  # not tmpfiles: the disk root belongs to justkowal, and tmpfiles refuses directories with other owners below it
  systemd.services.maps-dirs = {
    description = "Create the maps data directories";
    wantedBy = ["multi-user.target"];
    before = ["podman-mcp-nominatim.service" "podman-mcp-otp.service" "graph-watch.timer" "maps-export-sync.timer"];
    unitConfig.RequiresMountsFor = "/srv/data";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0755 ${data} ${data}/graph ${data}/graph/current ${data}/graph/previous ${data}/graph/quarantine \
        ${data}/adapters ${data}/osm ${data}/export ${data}/export/adapters ${data}/graph/info
      install -d -m 0750 -o maps-push -g maps-push ${data}/graph/upload
    '';
  };

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
          ("--health-cmd=" + builtins.toJSON ["bash" "-c" "exec 3<>/dev/tcp/127.0.0.1/8080; printf 'GET /otp HTTP/1.0\\r\\n\\r\\n' >&3; head -1 <&3 | grep -q 200"])
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

  # the desktop pushes into graph/upload and touches READY last; this verifies, stage-tests and swaps it in
  systemd.services.graph-watch = {
    description = "Verify, stage-test and swap in a pushed routing graph";
    environment = {
      DATA = data;
      OTP_IMAGE = "opentripplanner/opentripplanner@sha256:8d54e5c589186707ee365417f2202dc878c451fa3001b8edff07019531100933";
      JAVA_OPTS = otpJvm;
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe graphWatch;
      TimeoutStartSec = "20min";
    };
  };
  # a path unit cannot see READY appear inside a new subdirectory, so a short timer polls for it
  systemd.timers.graph-watch = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
    };
  };
}
