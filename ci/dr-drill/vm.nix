# x86_64 stand-in for the rpi4: same service modules, no Pi hardware, sd-image, ingress or containers.
# Stubs (things configuration.nix normally provides, or that cannot work offline):
#   - sops: throwaway age key + dummy secrets in this dir instead of the host key
#   - woodpecker-server.env template and the justkowal user copied from configuration.nix
#   - blocky, harmonia, glance, shiori, uptime-kuma disabled (need internet or a real signing key, not probed)
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  restore = "/mnt/restore";
  # units that must not start before their state is restored
  stateful = [
    "kanidm.service"
    "forgejo.service"
    "forgejo-secrets.service"
    "vaultwarden.service"
    "paperless-scheduler.service"
    "paperless-web.service"
    "paperless-task-queue.service"
    "paperless-consumer.service"
    "woodpecker-server.service"
  ];
  existing = lib.filter (u: config.systemd.services ? ${lib.removeSuffix ".service" u}) stateful;
in {
  imports = [
    inputs.sops-nix.nixosModules.sops
    ../../modules/lab-hosts.nix
    ../../modules/kanidm-client.nix
    ../../hosts/rpi4/apps.nix
  ];

  virtualisation = {
    memorySize = 4096;
    cores = 4;
    diskSize = 20480;
    sharedDirectories.restore = {
      source = ''"$DR_RESTORE_DIR"'';
      target = restore;
    };
  };

  sops = {
    defaultSopsFile = ./test-secrets.yaml;
    # sops-nix refuses store paths for the key, so it is copied out before decryption
    age.keyFile = "/var/lib/dr-drill/age-key.txt";
    age.sshKeyPaths = [];
    gnupg.sshKeyPaths = [];
    secrets."harmonia_signing_key" = {};
    secrets."woodpecker_agent_secret" = {};
    secrets."woodpecker_gitea_client" = {};
    secrets."woodpecker_gitea_secret" = {};
    templates."woodpecker-server.env".content = ''
      WOODPECKER_AGENT_SECRET=${config.sops.placeholder."woodpecker_agent_secret"}
      WOODPECKER_GITEA_CLIENT=${config.sops.placeholder."woodpecker_gitea_client"}
      WOODPECKER_GITEA_SECRET=${config.sops.placeholder."woodpecker_gitea_secret"}
    '';
  };

  system.activationScripts.drAgeKey.text = "${pkgs.coreutils}/bin/install -D -m 0400 ${./test-age-key.txt} /var/lib/dr-drill/age-key.txt";
  system.activationScripts.setupSecrets.deps = ["drAgeKey"];

  services.blocky.enable = lib.mkForce false;
  services.harmonia.cache.enable = lib.mkForce false;
  services.glance.enable = lib.mkForce false;
  services.shiori.enable = lib.mkForce false;
  services.uptime-kuma.enable = lib.mkForce false;

  users.users.justkowal = {
    isNormalUser = true;
    group = "users";
  };

  systemd.tmpfiles.rules = [
    "d /home/justkowal/Sync/Documents/consume 0777 justkowal users -"
    "d /home/justkowal/Sync/Backups/forgejo 0755 forgejo forgejo -"
  ];

  environment.systemPackages = [pkgs.sqlite pkgs.jq pkgs.curl];

  systemd.services.dr-import = {
    description = "Copy the restored restic snapshot into service state dirs";
    wantedBy = ["multi-user.target"];
    requiredBy = existing;
    before = existing;
    unitConfig.RequiresMountsFor = restore;
    path = [pkgs.coreutils pkgs.findutils pkgs.sqlite pkgs.unzip];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      R=${restore}
      S=$R/var/backup/offsite-staging
      [ -d "$S" ] || { echo "no offsite-staging dir in snapshot" >&2; exit 1; }

      install -d -m 0700 /var/lib/kanidm
      cp -a "$R/var/lib/kanidm/." /var/lib/kanidm/
      cp "$S/kanidm.db" /var/lib/kanidm/kanidm.db
      chown -R kanidm:kanidm /var/lib/kanidm

      install -d -m 0700 /var/lib/vaultwarden
      cp -a "$R/var/lib/vaultwarden/." /var/lib/vaultwarden/
      cp "$S/vaultwarden.sqlite3" /var/lib/vaultwarden/db.sqlite3
      # the real env holds the SSO client secret; it never enters the drill VM
      echo "SSO_CLIENT_SECRET=dr-drill-dummy" > /var/lib/vaultwarden/vaultwarden.env
      chown -R vaultwarden:vaultwarden /var/lib/vaultwarden

      install -d /var/lib/paperless
      cp -a "$R/var/lib/paperless/." /var/lib/paperless/
      cp "$S/paperless.sqlite3" /var/lib/paperless/db.sqlite3
      chown -R paperless:paperless /var/lib/paperless

      install -d -m 0700 /var/lib/private
      install -d -m 0700 /var/lib/private/woodpecker-server
      cp "$S/woodpecker.sqlite" /var/lib/private/woodpecker-server/woodpecker.sqlite

      dump=$(find "$R/home/justkowal/Sync/Backups/forgejo" -name '*.zip' -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)
      [ -n "$dump" ] || { echo "no forgejo dump in snapshot" >&2; exit 1; }
      tmp=$(mktemp -d)
      unzip -q "$dump" -d "$tmp"
      install -d /var/lib/forgejo/repositories /var/lib/forgejo/data /var/lib/forgejo/custom
      cp -a "$tmp/repos/." /var/lib/forgejo/repositories/
      [ -d "$tmp/data" ] && cp -a "$tmp/data/." /var/lib/forgejo/data/
      [ -d "$tmp/custom" ] && cp -a "$tmp/custom/." /var/lib/forgejo/custom/
      rm -f /var/lib/forgejo/data/forgejo.db
      sqlite3 /var/lib/forgejo/data/forgejo.db < "$(find "$tmp" -maxdepth 1 -name '*-db.sql' | head -n 1)"
      rm -rf "$tmp"
      chown -R forgejo:forgejo /var/lib/forgejo
    '';
  };
}
