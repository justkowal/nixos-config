{
  config,
  lib,
  pkgs,
  ...
}: let
  srv = config.lab.backup.server;
  off = config.lab.backup.offsite;
  port = "8010";
  staging = "/var/backup/offsite-staging";

  notifyUnit = {
    description = "Post backup failure of %i to ntfy";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe pkgs.curl} -s --max-time 20 -H 'Title: Backup failed on ${config.networking.hostName}' -H 'Priority: high' -d '%i failed, see journalctl -u %i' http://127.0.0.1:2586/backups";
    };
  };
in {
  options.lab.backup = {
    server = {
      enable = lib.mkEnableOption "append-only restic REST server at restic.lab";
      clients = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["nixos-desktop" "thinkpad-t14s-gen1-amd"];
        description = "Client hostnames; each gets a repo /<host>/ and a server-side forget/prune job.";
      };
      pruneOpts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["--keep-daily 7" "--keep-weekly 5" "--keep-monthly 12" "--keep-yearly 2"];
      };
    };

    offsite = {
      enable = lib.mkEnableOption "nightly restic backup of rpi4 state to an off-site repository";
      repository = lib.mkOption {
        type = lib.types.str;
        # placeholder Hetzner Storage Box; the path is relative to the box home
        default = "sftp:u000000@u000000.your-storagebox.de:restic-rpi4";
        description = "restic repository string (sftp:, rclone:, s3:, ...).";
      };
      extraOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = lib.optional (lib.hasPrefix "sftp:" off.repository)
          "sftp.args='-p 23 -i ${config.sops.secrets."restic_offsite_ssh_key".path} -o StrictHostKeyChecking=accept-new'";
        defaultText = "sftp.args for a Hetzner Storage Box (port 23, key from sops) when the repository is sftp:";
        description = "restic -o options, e.g. rclone.program or sftp.command.";
      };
      pruneOpts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["--keep-daily 7" "--keep-weekly 5" "--keep-monthly 12"];
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (srv.enable || off.enable) {
      systemd.services."backup-failed-ntfy@" = notifyUnit;
    })

    (lib.mkIf srv.enable {
      sops.secrets = {
        "restic_server_htpasswd" = {owner = "restic";};
      } // lib.genAttrs (map (h: "restic_${h}_password") srv.clients) (_: {owner = "restic";});

      services.restic.server = {
        enable = true;
        listenAddress = "127.0.0.1:${port}";
        appendOnly = true;
        privateRepos = true;
        htpasswd-file = config.sops.secrets."restic_server_htpasswd".path;
      };

      # clients cannot delete in append-only mode, so retention runs here with direct repo access
      services.restic.backups = lib.listToAttrs (map (h:
        lib.nameValuePair "prune-${h}" {
          repository = "${config.services.restic.server.dataDir}/${h}";
          passwordFile = config.sops.secrets."restic_${h}_password".path;
          user = "restic";
          pruneOpts = srv.pruneOpts;
          runCheck = true;
          timerConfig = {
            OnCalendar = "Sun 05:00";
            Persistent = true;
          };
        })
      srv.clients);

      systemd.services = lib.listToAttrs (map (h:
        lib.nameValuePair "restic-backups-prune-${h}" {
          onFailure = ["backup-failed-ntfy@%n.service"];
          # a client that never ran has no repo yet
          unitConfig.ConditionPathExists = "${config.services.restic.server.dataDir}/${h}/config";
        })
      srv.clients);

      services.caddy.virtualHosts."https://restic.lab".extraConfig = ''
        tls internal
        reverse_proxy localhost:${port}
      '';
      networking.hosts."127.0.0.1" = ["restic.lab"];
    })

    (lib.mkIf off.enable {
      sops.secrets."restic_offsite_password" = {};
      sops.secrets."restic_offsite_ssh_key" = lib.mkIf (lib.hasPrefix "sftp:" off.repository) {};

      services.restic.backups.offsite = {
        inherit (off) repository extraOptions pruneOpts;
        passwordFile = config.sops.secrets."restic_offsite_password".path;
        initialize = true;
        # live sqlite files are not crash-safe to copy, so back up .backup snapshots instead
        backupPrepareCommand = ''
          set -eu
          ${pkgs.coreutils}/bin/install -d -m 0700 ${staging}
          dump() { if [ -f "$1" ]; then ${lib.getExe pkgs.sqlite} "$1" ".backup ${staging}/$2"; fi; }
          dump /var/lib/paperless/db.sqlite3 paperless.sqlite3
          dump /var/lib/private/woodpecker-server/woodpecker.sqlite woodpecker.sqlite
          dump /var/lib/vaultwarden/db.sqlite3 vaultwarden.sqlite3
          dump /var/lib/kanidm/kanidm.db kanidm.db
        '';
        backupCleanupCommand = "${pkgs.coreutils}/bin/rm -rf ${staging}";
        paths = [
          staging
          "/home/justkowal/Sync/Backups"
          "/var/lib/paperless"
          "/var/lib/vaultwarden"
          "/var/lib/kanidm"
        ];
        exclude = [
          "/var/lib/paperless/db.sqlite3*"
          "/var/lib/paperless/index"
          "/var/lib/vaultwarden/db.sqlite3*"
          "/var/lib/vaultwarden/icon_cache"
          "/var/lib/kanidm/kanidm.db*"
        ];
        timerConfig = {
          OnCalendar = "04:15";
          Persistent = true;
        };
      };

      systemd.services.restic-backups-offsite = {
        after = ["homelab-state-backup.service" "forgejo-dump.service"];
        onFailure = ["backup-failed-ntfy@%n.service"];
      };
    })
  ];
}
