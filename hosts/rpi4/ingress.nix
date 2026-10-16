{
  config,
  lib,
  pkgs,
  ...
}: {
  # ── Caddy: Tailnet reverse proxy + GRUB boot-state endpoint ───────────
  services.caddy = {
    enable = true;
    globalConfig = ''
      pki {
        ca local {
          name "Homelab Internal Root CA"
          root {
            cert /var/lib/caddy/pki/homelab-ca.crt
            key  /var/lib/caddy/pki/homelab-ca.key
          }
        }
      }
    '';
    virtualHosts = {
      # GRUB fetches boot-state.cfg over plain HTTP during early boot (no TLS stack in GRUB)
      # Security: only reachable on Tailnet (trustedInterfaces) and LAN — never public internet
      ":80" = {
        extraConfig = ''
          root * /var/www/boot-state
          file_server
        '';
      };
      # Flamenco Manager — HTTP for worker connectivity (Tailnet is already encrypted)
      "http://render.lab" = {
        extraConfig = ''
          reverse_proxy localhost:8080
        '';
      };
      "https://portfolio.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:3080
        '';
      };
      "https://git.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:3000
        '';
      };
      "https://ci.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:8000
        '';
      };
      "https://idm.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy https://localhost:8443 {
            transport http {
              tls_insecure_skip_verify
            }
          }
        '';
      };
      "https://vault.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:8222
        '';
      };
      "https://ntfy.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:2586
        '';
      };
      "https://status.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:3001
        '';
      };
      # Glance: Private Homelab Dashboard (Strictly Tailnet & LAN only, no Cloudflare tunnel)
      "https://lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:8095
        '';
      };
      "https://home.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:8095
        '';
      };
      "https://bookmarks.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:8085
        '';
      };
      "https://docs.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:28981
        '';
      };
      "https://cache.lab" = {
        extraConfig = ''
          tls internal
          reverse_proxy localhost:5000
        '';
      };
    };
  };

  # ── Cloudflared: public tunnel for portfolio & dynamic subdomains ───────
  # Runs outbound connection to Cloudflare edge — functions 100% cleanly behind CGNAT.
  # Wildcard *.23012006.xyz routes directly to Traefik, which dynamically connects
  # to any container exposing `traefik.enable=true` and matching Host rules.
  # Cloudflared will be enabled once credentials exist at /var/lib/cloudflared/homelab-credentials.json
  # (See docs/DEPLOYMENT.md §2.5.A)
  services.cloudflared = {
    enable = true;
    tunnels."fd29c003-2ef3-45e8-bd0f-a453b25a4c31" = {
      credentialsFile = "/var/lib/cloudflared/homelab-credentials.json";
      default = "http_status:404";
      ingress = {
        "portfolio.23012006.xyz" = {
          service = "http://localhost:3080";
        };
        "portfolio.justkowal.dev" = {
          service = "http://localhost:3080";
        };
        "vault.23012006.xyz" = {
          service = "http://localhost:8222";
        };
        "ntfy.23012006.xyz" = {
          service = "http://localhost:2586";
        };
        "status.23012006.xyz" = {
          service = "http://localhost:3001";
        };
        "git.23012006.xyz" = {
          service = "http://localhost:3000";
        };
        "git.justkowal.dev" = {
          service = "http://localhost:3000";
        };
        "*.23012006.xyz" = {
          service = "http://127.0.0.1:8088";
        };
        "23012006.xyz" = {
          service = "http://127.0.0.1:8088";
        };
      };
    };
  };

  # ── Traefik: Dynamic Container Router for Cloudflare Ingress ───────────
  # Listens only on loopback (127.0.0.1:8088) behind Cloudflared tunnel.
  # Watches the Podman socket for container labels (e.g. `traefik.http.routers.app.rule=Host(...)`).
  # Security: `exposedByDefault = false` guarantees internal services are never exposed.
  services.traefik = {
    enable = true;
    group = "podman";
    staticConfigOptions = {
      entryPoints.web = {
        address = "127.0.0.1:8088";
      };
      providers.docker = {
        endpoint = "unix:///run/podman/podman.sock";
        exposedByDefault = false;
        network = "podman";
      };
      global = {
        checkNewVersion = false;
        sendAnonymousUsage = false;
      };
    };
  };

  users.users.traefik.extraGroups = [ "podman" ];
}
