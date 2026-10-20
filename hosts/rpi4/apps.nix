{
  config,
  lib,
  pkgs,
  ...
}: {
  # ── Forgejo (Git forge + OCI container registry) ───────────────────────
  #
  # ┌─── OIDC SSO SETUP (post-deploy, one-time) ────────────────────────┐
  # │ 1. In Kanidm, create an OAuth2 Resource Server for Forgejo:       │
  # │                                                                    │
  # │    kanidm system oauth2 create forgejo "Forgejo" https://git.lab  │
  # │    kanidm system oauth2 add-redirect-url forgejo \                │
  # │      https://git.lab/user/oauth2/kanidm/callback                  │
  # │    kanidm system oauth2 show-basic-secret forgejo                 │
  # │                                                                    │
  # │ 2. In Forgejo Admin → Site Administration → Authentication:       │
  # │    Add Authentication Source → OAuth2                              │
  # │      Provider:       OpenID Connect                                │
  # │      Client ID:      forgejo                                       │
  # │      Client Secret:  <secret from step 1>                          │
  # │      Discovery URL:  https://idm.lab/oauth2/openid/forgejo/       │
  # │                      .well-known/openid-configuration             │
  # │      Scopes:         openid profile email                          │
  # │      Required Claim: (leave empty for all Kanidm users)           │
  # └───────────────────────────────────────────────────────────────────┘
  services.forgejo = {
    enable = true;
    database.type = "sqlite3";
    dump = {
      enable = true;
      backupDir = "/home/justkowal/Sync/Backups/forgejo";
      interval = "03:00";
      type = "zip";
      age = "14d";
    };
    settings = {
      DEFAULT.APP_NAME = "Homelab Forge";
      server = {
        DOMAIN = "git.lab";
        ROOT_URL = "https://git.lab/";
        HTTP_PORT = 3000;
      };
      packages.ENABLED = true;
      registry.ENABLED = true;
      # Low-memory optimisations for 4GB RPi4
      cache.ADAPTER = "memory";
      session.PROVIDER = "memory";
      indexer.REPO_INDEXER_ENABLED = false;
    };
  };

  # ── Woodpecker CI Server ───────────────────────────────────────────────
  # secrets come from sops (see the sops block); the forgejo oauth app redirects to https://ci.lab/authorize
  services.woodpecker-server = {
    enable = true;
    environment = {
      WOODPECKER_HOST = "https://ci.lab";
      WOODPECKER_OPEN = "false";
      WOODPECKER_ADMIN = "justkowal";
      WOODPECKER_GITEA = "true";
      WOODPECKER_GITEA_URL = "https://git.lab";
      WOODPECKER_GRPC_ADDR = "0.0.0.0:9000";
    };
    environmentFile = config.sops.templates."woodpecker-server.env".path;
  };

  # ── Syncthing ──────────────────────────────────────────────────────────
  services.syncthing = {
    enable = true;
    user = "justkowal";
    dataDir = "/home/justkowal/Sync";
    configDir = "/home/justkowal/.config/syncthing";
    guiAddress = "127.0.0.1:8384";
    openDefaultPorts = true;
  };

  # ── Kanidm Server (Identity Provider) ──────────────────────────────────
  #
  # ┌─── POST-DEPLOY INITIALIZATION ────────────────────────────────────┐
  # │ 1. kanidm recover-account admin                                   │
  # │ 2. kanidm login --name admin                                      │
  # │ 3. kanidm group create linux_users                                │
  # │ 4. kanidm person create justkowal "justkowal"                     │
  # │ 5. kanidm group add-members linux_users justkowal                 │
  # │ 6. kanidm person posix set justkowal --shell /bin/bash            │
  # └───────────────────────────────────────────────────────────────────┘
  services.kanidm = {
    server.enable = true;
    server.settings = {
      origin = "https://idm.lab";
      domain = "idm.lab";
      bindaddress = "127.0.0.1:8443";
      tls_chain = "/var/lib/kanidm/cert.pem";
      tls_key = "/var/lib/kanidm/key.pem";
      db_arc_size = 536870912;  # 512MB cache limit for 4GB RPi4
    };
  };

  # ── Vaultwarden: Lightweight Bitwarden Password Manager ───────────────
  #
  # ┌─── KANIDM OIDC SSO INITIALIZATION ────────────────────────────────┐
  # │ 1. In Kanidm, register an OAuth2 client for Vaultwarden:          │
  # │    kanidm system oauth2 create vaultwarden "Vaultwarden" \         │
  # │      https://vault.lab                                            │
  # │    kanidm system oauth2 add-redirect-url vaultwarden \            │
  # │      https://vault.lab/identity/connect/oidc-signin               │
  # │    kanidm system oauth2 show-basic-secret vaultwarden             │
  # │ 2. Populate /var/lib/vaultwarden/vaultwarden.env with:            │
  # │    SSO_CLIENT_SECRET=<secret from show-basic-secret>              │
  # └───────────────────────────────────────────────────────────────────┘
  services.vaultwarden = {
    enable = true;
    config = {
      ROCKET_PORT = 8222;
      ROCKET_ADDRESS = "127.0.0.1";
      DOMAIN = "https://vault.lab";
      SIGNUPS_ALLOWED = true;
      # Kanidm SSO / OpenID Connect
      SSO_ENABLED = true;
      SSO_AUTHORITY = "https://idm.lab/oauth2/openid/vaultwarden";
      SSO_CLIENT_ID = "vaultwarden";
      SSO_SCOPES = "openid profile email";
    };
    environmentFile = "/var/lib/vaultwarden/vaultwarden.env";
  };

  # ── ntfy: Unified Push Notification Dispatcher ─────────────────────────
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.lab";
      listen-http = "127.0.0.1:2586";
      # promote-stable reads 24h of fleet-health reports; the default cache is 12h
      cache-duration = "48h";
    };
  };

  # ── Uptime Kuma: Homelab Status & Health Dashboard ─────────────────────
  services.uptime-kuma = {
    enable = true;
    settings = {
      PORT = "3001";
      HOST = "127.0.0.1";
    };
  };

  # ── Glance: Private Homelab Dashboard (Tailnet & LAN Only) ─────────────
  services.glance = {
    enable = true;
    settings = {
      server = {
        host = "127.0.0.1";
        port = 8095;
      };
      theme = {
        background-color = "240 10 4";
        primary-color = "350 80 75";
      };
      pages = [
        {
          name = "Homelab";
          columns = [
            {
              size = "small";
              widgets = [
                {
                  type = "clock";
                  time-format = "24h";
                }
                {
                  type = "monitor";
                  title = "RPi4 Node";
                }
              ];
            }
            {
              size = "full";
              widgets = [
                {
                  type = "bookmarks";
                  groups = [
                    {
                      title = "Core Infrastructure";
                      links = [
                        { title = "Kanidm IDM"; url = "https://idm.lab"; }
                        { title = "Forgejo Git"; url = "https://git.lab"; }
                        { title = "Woodpecker CI"; url = "https://ci.lab"; }
                        { title = "Uptime Kuma Status"; url = "https://status.lab"; }
                      ];
                    }
                    {
                      title = "Workstation & Services";
                      links = [
                        { title = "Vaultwarden"; url = "https://vault.lab"; }
                        { title = "Flamenco Render Manager"; url = "http://render.lab"; }
                        { title = "ntfy Push Alerts"; url = "https://ntfy.lab"; }
                        { title = "Desktop Sunshine"; url = "https://nixos-desktop.lab:47990"; }
                        { title = "Shiori Bookmarks"; url = "https://bookmarks.lab"; }
                        { title = "Paperless Docs"; url = "https://docs.lab"; }
                      ];
                    }
                  ];
                }
              ];
            }
          ];
        }
      ];
    };
  };

  # ── Shiori: Self-Hosted Bookmarks & Web Archiver ───────────────────────
  # Note: Shiori is a minimalist standalone Go bookmark manager with internal
  # SQLite user accounts. To register with Kanidm OAuth2:
  #   kanidm system oauth2 create shiori "Shiori Bookmarks" https://bookmarks.lab
  #   kanidm system oauth2 add-redirect-url shiori https://bookmarks.lab/oauth/callback
  services.shiori = {
    enable = true;
    port = 8085;
  };

  # ── Paperless-ngx: Automated Document & Receipt Archiver ───────────────
  #
  # ┌─── KANIDM OIDC SSO INITIALIZATION ────────────────────────────────┐
  # │ 1. In Kanidm, register an OAuth2 client for Paperless:            │
  # │    kanidm system oauth2 create paperless "Paperless-ngx" \        │
  # │      https://docs.lab                                             │
  # │    kanidm system oauth2 add-redirect-url paperless \              │
  # │      https://docs.lab/accounts/oidc/kanidm/login/callback/        │
  # │    kanidm system oauth2 show-basic-secret paperless               │
  # └───────────────────────────────────────────────────────────────────┘
  services.paperless = {
    enable = true;
    address = "127.0.0.1";
    port = 28981;
    consumptionDir = "/home/justkowal/Sync/Documents/consume";
    consumptionDirIsPublic = true;
    settings = {
      PAPERLESS_URL = "https://docs.lab";
      PAPERLESS_OCR_LANGUAGE = "pol+eng";
      PAPERLESS_TIME_ZONE = "Europe/Warsaw";
      PAPERLESS_TASK_WORKERS = 1;
      PAPERLESS_THREADS_PER_WORKER = 1;
      # Kanidm SSO / OpenID Connect via django-allauth
      PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
      PAPERLESS_SOCIALACCOUNT_PROVIDERS = builtins.toJSON {
        openid_connect = {
          OAUTH_PKCE_ENABLED = true;
          APPS = [
            {
              provider_id = "kanidm";
              name = "Kanidm IDM";
              client_id = "paperless";
              settings = {
                server_url = "https://idm.lab/oauth2/openid/paperless/.well-known/openid-configuration";
              };
            }
          ];
          SCOPE = [ "openid" "profile" "email" ];
        };
      };
    };
  };

  # the first start runs django migrations, which take longer than the module's 15 s start limit on a
  # Pi 4 under load. The unit was killed and restarted 66k times (and held every later activation
  # hostage) before this. Give it time and stop it hammering the CPU between attempts.
  systemd.services.paperless-scheduler.serviceConfig = {
    TimeoutStartSec = lib.mkForce "15min";
    RestartSec = lib.mkForce "30s";
  };

  # the consume folder sits under the user's home, which is mode 700. Paperless only needs to walk
  # through it (x, no listing); the folders below are already open. Without this the pre-start
  # check fails with PermissionError and the unit loops, which also stalls every activation.
  # the explicit mask is needed: a named ACL entry alone is ignored while the mask is ---.
  systemd.tmpfiles.rules = [
    "a+ /home/justkowal - - - - u:paperless:--x,m::--x"
  ];

  # ── Blocky: Fast DNS Proxy, Ad-Blocker & Homelab Split-DNS ─────────────
  services.blocky = {
    enable = true;
    settings = {
      # not plain 53: podman's aardvark-dns owns 10.88.0.1:53 and a wildcard bind crashes Blocky on
      # start, which also takes its http api (focus mode) down. Loopback, the home LAN and the tailnet.
      ports.dns = [
        "127.0.0.1:53"
        "192.168.1.22:53"
        "100.113.193.14:53"
      ];
      upstreams.groups.default = [
        "1.1.1.1"
        "1.0.0.1"
      ];
      customDNS = {
        customTTL = "1h";
        mapping = config.lab.dnsMapping;
      };
      blocking = {
        denylists = {
          ads = [
            "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
          ];
        };
        clientGroupsBlock = {
          default = [ "ads" ];
        };
      };
    };
  };

  # the tailnet address only exists once tailscale is up, so retry calmly instead of in a hot loop
  systemd.services.blocky = {
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig.RestartSec = lib.mkForce "5s";
  };

  # ── Harmonia: Shared Binary Cache ──────────────────────────────────────
  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ config.sops.secrets."harmonia_signing_key".path ];
    settings.bind = "127.0.0.1:5000";
  };

  # CI (.woodpecker.yaml) pushes closures here. harmonia signs on serve, so pushed paths arrive
  # unsigned and the pusher has to be trusted; the key can only speak the daemon protocol.
  users.users.nix-push = {
    isSystemUser = true;
    group = "nix-push";
    useDefaultShell = true;
    openssh.authorizedKeys.keys = [
      ''restrict,command="${config.nix.package}/bin/nix-daemon --stdio" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFB8sko/gnZMJAC9ac+pfbXL6L2Sl47r/Cl3jkgHiIHq woodpecker-cache-push''
    ];
  };
  users.groups.nix-push = {};
  nix.settings.trusted-users = [ "nix-push" ];
}
