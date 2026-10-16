{config, lib, pkgs, ...}: let
  cfg = config.lab.streamWake;

  statusScript = pkgs.writeShellScript "stream-status" ''
    if ${pkgs.netcat}/bin/nc -z -w 1 nixos-desktop.lab ${toString cfg.sunshinePort} 2>/dev/null; then
      echo up
    else
      echo down
    fi
  '';

  page = pkgs.writeTextDir "index.html" ''
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>play.lab</title>
    <style>
      :root { --bg: #f6f6f4; --fg: #141414; --muted: #6b6b6b; --ok: #1f7a3f; --line: #d9d9d4; }
      @media (prefers-color-scheme: dark) {
        :root { --bg: #111211; --fg: #ececea; --muted: #8f8f8a; --ok: #5fcf86; --line: #2a2b29; }
      }
      body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--fg);
             font: 16px/1.5 system-ui, sans-serif; }
      main { width: min(28rem, 100% - 2rem); border-top: 2px solid var(--line); padding-top: 1.25rem; }
      h1 { font-size: 1.5rem; margin: 0 0 .25rem; letter-spacing: -.01em; }
      p { margin: .25rem 0; color: var(--muted); }
      #state { color: var(--fg); font-weight: 600; }
      main.up #state { color: var(--ok); }
    </style>
    </head>
    <body>
    <main id="box">
      <h1>nixos-desktop</h1>
      <p><span id="state">Checking</span> <span id="elapsed"></span></p>
      <p id="hint">Sunshine answers once the desktop has booted. Keep this page open.</p>
    </main>
    <script>
      const t0 = Date.now();
      const el = (id) => document.getElementById(id);
      let woken = false;
      async function poll() {
        el("elapsed").textContent = Math.round((Date.now() - t0) / 1000) + " s";
        try {
          const r = await fetch("/status", { method: "POST", cache: "no-store" });
          if ((await r.text()).trim() === "up") {
            el("box").className = "up";
            el("state").textContent = "Ready";
            el("hint").textContent = "Open Moonlight and connect to nixos-desktop.";
            return;
          }
        } catch (e) {}
        // only wake when it is really down: wake-worker leaves the next boot target at "server"
        if (!woken) {
          woken = true;
          fetch("/wake", { method: "POST" }).catch(() => {});
          el("state").textContent = "Booting";
        }
        if (Date.now() - t0 > 300000) {
          el("state").textContent = "No answer after 5 minutes";
          el("hint").textContent = "Check the desktop or reload to send another wake signal.";
          return;
        }
        setTimeout(poll, 2000);
      }
      poll();
    </script>
    </body>
    </html>
  '';
in {
  options.lab.streamWake = {
    enable = lib.mkEnableOption "play.lab: wake the desktop for Moonlight and wait for Sunshine";
    wakeHook = lib.mkOption {
      type = lib.types.enum ["wake-worker" "wake-desktop"];
      # desktop mode stops at the greetd login, where Sunshine (a graphical-session user unit) never starts
      default = "wake-worker";
    };
    sunshinePort = lib.mkOption {
      type = lib.types.port;
      default = 47989;
    };
  };

  config = lib.mkIf cfg.enable {
    lab.webhookHooks = [
      {
        id = "stream-status";
        execute-command = toString statusScript;
        include-command-output-in-response = true;
      }
    ];

    services.caddy.virtualHosts."https://play.lab".extraConfig = ''
      tls internal
      handle /wake {
        rewrite * /hooks/${cfg.wakeHook}
        reverse_proxy localhost:9100
      }
      handle /status {
        rewrite * /hooks/stream-status
        reverse_proxy localhost:9100
      }
      handle {
        root * ${page}
        file_server
      }
    '';
  };
}
