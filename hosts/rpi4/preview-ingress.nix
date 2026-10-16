{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.lab.previewIngress;

  # reuse the existing hook so boot-target handling stays in one place
  wake = pkgs.writeShellScript "preview-wake" ''
    ${pkgs.curl}/bin/curl -fsS -X POST http://127.0.0.1:9100/hooks/wake-worker
  '';

  wakingPage = ''
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="refresh" content="15">
    <title>Waking the preview host</title>
    <style>
      :root { color-scheme: light dark; }
      body { font: 16px/1.5 system-ui, sans-serif; max-width: 34rem; margin: 18vh auto; padding: 0 16px; }
      h1 { font-size: 1.25rem; margin: 0 0 .5rem; }
      p { margin: 0; opacity: .75; }
    </style></head>
    <body><h1>The preview host is asleep.</h1>
    <p>A wake signal was sent. Boot takes about a minute; this page reloads every 15 seconds.</p>
    </body></html>
  '';
in {
  options.lab.previewIngress.enable = lib.mkEnableOption "*.dev.lab ingress to desktop preview containers with wake-on-request";

  config = lib.mkIf cfg.enable {
    lab.webhookHooks = [
      {
        id = "preview-wake";
        execute-command = toString wake;
        response-message = wakingPage;
        success-http-response-code = 503;
        response-headers = [
          {
            name = "Content-Type";
            value = "text/html; charset=utf-8";
          }
          {
            name = "Retry-After";
            value = "15";
          }
        ];
      }
    ];

    # the desktop's own caddy routes by Host header to the right container
    services.caddy.virtualHosts."https://*.dev.lab".extraConfig = ''
      tls internal
      reverse_proxy http://nixos-desktop.lab:80 {
        transport http {
          dial_timeout 3s
        }
      }
      handle_errors 502 503 504 {
        rewrite * /hooks/preview-wake
        reverse_proxy 127.0.0.1:9100
      }
    '';
  };
}
