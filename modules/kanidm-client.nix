{ config, lib, pkgs, ... }:

{
  # ── Kanidm Unified Identity Client ──────────────────────────────────────
  # Connects to the Kanidm IdP on the Pi4 (idm.lab) for:
  #   - OS-level PAM authentication (su, sudo, greetd, hyprlock)
  #   - SSH public key distribution via kanidm-unixd
  #   - NSS user/group resolution (passwd, group databases)
  #
  # Credentials are cached locally in cache_db so the laptop works offline.
  # Local emergency accounts (wheel group, justkowal) are unaffected —
  # NSS resolves local /etc/passwd first (mkOrder 400) before Kanidm (mkOrder 490).

  services.kanidm = {
    package = lib.mkDefault pkgs.kanidm_1_11;
    client.enable = true;
    client.settings = {
      uri = "https://idm.lab";
    };

    unix = {
      enable = true;
      sshIntegration = true;
      settings = {
        kanidm = {
          pam_allowed_login_groups = [ "linux_users" ];
        };
        # Offline credential cache — survives network outages and laptop travel
        cache_db = "/var/cache/kanidm-unixd/cache.db";
        home_mount_prefix = "/home/";
        home_attr = "uuid";
        home_alias = "spn";
        default_shell = "/run/current-system/sw/bin/bash";
      };
    };
  };

  # Ensure local /etc/passwd and /etc/group resolve before Kanidm
  # to prevent local accounts (justkowal, root) from colliding with domain accounts
  system.nssDatabases.passwd = lib.mkForce [ "files" "kanidm" "systemd" ];
  system.nssDatabases.group = lib.mkForce [ "files" "kanidm" "[success=merge] systemd" ];
}

