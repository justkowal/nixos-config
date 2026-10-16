{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.lab.backup.client;
  host = config.networking.hostName;
  home = "/home/justkowal";
in {
  options.lab.backup.client.enable = lib.mkEnableOption "daily restic backup of ~ to the rpi4 REST server";

  config = lib.mkIf cfg.enable {
    sops.secrets."restic_${host}_password" = {};
    sops.secrets."restic_${host}_rest_password" = {};
    # rest-server private repos: the username must equal the repo path
    sops.templates."restic-rest.env".content = ''
      RESTIC_REST_USERNAME=${host}
      RESTIC_REST_PASSWORD=${config.sops.placeholder."restic_${host}_rest_password"}
    '';

    services.restic.backups.home = {
      repository = "rest:https://restic.lab/${host}/";
      passwordFile = config.sops.secrets."restic_${host}_password".path;
      environmentFile = config.sops.templates."restic-rest.env".path;
      initialize = true;
      inhibitsSleep = true;
      paths = [home];
      exclude = map (p: "${home}/${p}") [
        ".cache"
        ".local/share/Trash"
        ".local/share/Steam"
        ".steam"
        ".local/share/containers"
        ".local/share/docker"
        ".local/share/libvirt/images"
        ".local/share/gnome-boxes"
        ".var/app/*/cache"
        "Sync"
        ".snapshots"
      ] ++ [
        "node_modules"
        "*.qcow2"
        "*.vdi"
        "*.vmdk"
      ];
      extraBackupArgs = ["--exclude-caches" "--exclude-if-present" ".nobackup"];
      # the server is append-only, so forget/prune runs on the rpi4 (lab.backup.server)
      pruneOpts = [];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    systemd.services.restic-backups-home = {
      onFailure = ["backup-failed-ntfy@%n.service"];
      # off-tailnet laptop: skip instead of failing; staleness is caught by monitoring
      serviceConfig.ExecCondition = "${lib.getExe pkgs.curl} -s -o /dev/null --max-time 10 https://restic.lab/";
      # feeds the BackupStale rule in hosts/rpi4/monitoring.nix
      serviceConfig.ExecStartPost = pkgs.writeShellScript "restic-success-metric" ''
        d=/var/lib/node-exporter-textfile
        [ -d "$d" ] || exit 0
        echo "restic_last_success_timestamp_seconds $(date +%s)" > "$d/restic.prom.tmp"
        mv "$d/restic.prom.tmp" "$d/restic.prom"
      '';
    };

    systemd.services."backup-failed-ntfy@" = {
      description = "Post backup failure of %i to ntfy";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pkgs.curl} -s --max-time 20 -H 'Title: Backup failed on ${host}' -H 'Priority: high' -d '%i failed, see journalctl -u %i' https://ntfy.lab/backups";
      };
    };
  };
}
