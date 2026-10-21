{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.lab.maps.adapters;
  data = "/srv/data/kowal-lab-maps";
  secretsDir = "/var/lib/mcp-gateway/secrets";

  # each adapter is its own image built on the Pi from its Dockerfile (python slim pinned by digest, hash-locked pip)
  adapters = {
    mpk-czestochowa = {
      dir = ../../pkgs/maps/adapters/mpk-czestochowa;
      target = null;
      zip = "gtfs.zip";
      secret = null;
    };
    plk-trains = {
      dir = ../../pkgs/maps/adapters/plk-trains;
      target = "final";
      zip = "out/gtfs.zip";
      secret = "plk_api_key";
    };
    komunikacja-jurajska = {
      dir = ../../pkgs/maps/adapters/komunikacja-jurajska;
      target = "final";
      zip = "gtfs.zip";
      secret = null;
    };
    # realtime only: rewrites the GZM trip ids to the ones of the static feed the desktop builds from
    gzm-rt = {
      dir = ../../pkgs/maps/adapters/gzm-rt;
      target = "final";
      zip = null;
      secret = null;
    };
  };

  enabled = lib.filterAttrs (n: _: cfg.${n}.enable) adapters;

  ctx = n: a: pkgs.runCommand "adapter-ctx-${n}" {} "cp -r ${a.dir} $out";
  tag = n: a: builtins.substring 11 8 (builtins.baseNameOf (ctx n a));
in {
  options.lab.maps.adapters = lib.genAttrs (builtins.attrNames adapters) (n: {
    enable = lib.mkEnableOption "the ${n} feed adapter container (needs the owner's approval, see docs/MAPS.md)";
  });

  config = lib.mkIf (enabled != {}) {
    # state directories, owned by the container user; created here because tmpfiles refuses paths under the disk root
    systemd.services = {
      maps-adapter-dirs = {
        description = "Create the adapter data directories";
        wantedBy = ["multi-user.target"];
        before = lib.mapAttrsToList (n: _: "podman-mcp-adapter-${n}.service") enabled;
        after = ["maps-dirs.service"];
        requires = ["maps-dirs.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = lib.concatStringsSep "\n" (lib.mapAttrsToList (n: _: "install -d -m 0750 -o 10001 -g 10001 ${data}/adapters/${n}") enabled);
      };
    }
    // lib.mapAttrs' (n: a:
      lib.nameValuePair "mcp-adapter-${n}-image" {
        description = "Build the ${n} adapter image";
        wantedBy = ["multi-user.target"];
        before = ["podman-mcp-adapter-${n}.service"];
        after = ["network-online.target"];
        wants = ["network-online.target"];
        path = [pkgs.podman];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = "30min";
        };
        # --format docker so the Dockerfile HEALTHCHECK is kept
        script = "podman image exists mcp-adapter-${n}:${tag n a} || podman build --format docker ${lib.optionalString (a.target != null) "--target ${a.target}"} -t mcp-adapter-${n}:${tag n a} ${ctx n a}";
      })
    enabled
    // lib.mapAttrs' (n: a:
      lib.nameValuePair "podman-mcp-adapter-${n}" {
        requires = ["mcp-adapter-${n}-image.service" "maps-adapter-dirs.service" "podman-network-mcp.service"];
        after = ["mcp-adapter-${n}-image.service" "maps-adapter-dirs.service" "podman-network-mcp.service"];
        # the key file must exist and be readable by the container user before the service starts
        unitConfig = lib.mkIf (a.secret != null) {ConditionPathExists = "${secretsDir}/${a.secret}";};
      })
    enabled
    // {
      # the desktop pulls each adapter's static zip through the export folder, never from the container
      maps-export-sync.serviceConfig.ExecStartPost = [
        (pkgs.writeShellScript "maps-export-adapters" (lib.concatStringsSep "\n" (lib.mapAttrsToList (n: a: lib.optionalString (a.zip != null) ''
            [ -f ${data}/adapters/${n}/${a.zip} ] && ${pkgs.rsync}/bin/rsync -a --chown=maps-pull:maps-pull ${data}/adapters/${n}/${a.zip} ${data}/export/adapters/${n}.zip
          '')
          enabled)
        + "\nexit 0\n"))
      ];
    };

    virtualisation.oci-containers.containers = lib.mapAttrs' (n: a:
      lib.nameValuePair "mcp-adapter-${n}" {
        image = "mcp-adapter-${n}:${tag n a}";
        autoStart = true;
        user = "10001:10001";
        volumes =
          ["${data}/adapters/${n}:/data:rw"]
          ++ lib.optional (a.secret != null) "${secretsDir}/${a.secret}:/run/secrets/${a.secret}:ro";
        # outbound for the source it reads, reachable by OTP on the internal network, publishes no port
        extraOptions = [
          "--network=mcp-internal"
          "--network=mcp"
          "--read-only"
          "--tmpfs=/tmp:rw,size=32m,mode=1777"
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
          "--memory=256m"
          "--cpus=1"
          "--pids-limit=128"
          "--log-driver=json-file"
          "--log-opt=max-size=5m"
          "--log-opt=max-file=3"
        ];
      })
    enabled;

    # the file secret keeps its host owner and mode, so the container user (10001) must be able to read it
    systemd.tmpfiles.rules = ["d ${secretsDir} 0750 root root -"] ++ lib.concatMap (a: lib.optional (a.secret != null) "z ${secretsDir}/${a.secret} 0640 root 10001 -") (lib.attrValues enabled);
  };
}
