{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.lab.monitoring.server;
  vm = "http://127.0.0.1:8428";
  realFs = ''fstype!~"tmpfs|ramfs|devtmpfs|overlay|squashfs|vfat|efivarfs"'';
in {
  options.lab.monitoring.server = {
    enable = lib.mkEnableOption "VictoriaMetrics, vmalert and the ntfy alert sink";
    alwaysOnHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["nixos-rpi4"];
      description = "Hosts that get a node-down alert; desktop and laptop sleep on purpose.";
    };
    ntfyUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://ntfy.lab/alerts";
    };
  };

  config = lib.mkIf cfg.enable {
    services.victoriametrics = {
      enable = true;
      listenAddress = ":8428";
      retentionPeriod = "90d";
      extraOptions = [
        "-memory.allowedPercent=15"
        "-search.maxConcurrentRequests=2"
        "-search.maxQueueDuration=30s"
        "-search.maxUniqueTimeseries=50000"
        "-dedup.minScrapeInterval=30s"
      ];
    };
    systemd.services.victoriametrics.serviceConfig.MemoryMax = "768M";

    # LAN clients; tailscale0 is already trusted
    networking.firewall.allowedTCPPorts = [8428];

    services.vmalert.instances.lab = {
      enable = true;
      settings = {
        "datasource.url" = vm;
        "remoteWrite.url" = vm;
        "remoteRead.url" = vm;
        "notifier.url" = ["http://127.0.0.1:9094"];
        "httpListenAddr" = "127.0.0.1:8880";
        "external.url" = "https://metrics.lab";
      };
      rules.groups = [
        {
          name = "fleet";
          interval = "1m";
          rules = [
            {
              alert = "DiskAlmostFull";
              expr = ''(1 - node_filesystem_avail_bytes{${realFs}} / node_filesystem_size_bytes{${realFs}}) * 100 > 85'';
              for = "15m";
              annotations.summary = "{{ $labels.mountpoint }} on {{ $labels.instance }} is {{ $value | printf \"%.0f\" }}% full";
            }
            {
              alert = "SystemdUnitFailed";
              expr = ''node_systemd_unit_state{state="failed"} == 1'';
              for = "5m";
              annotations.summary = "{{ $labels.name }} failed on {{ $labels.instance }}";
            }
            {
              # only fires once a backup job exports the metric via the textfile collector
              alert = "BackupStale";
              expr = "time() - restic_last_success_timestamp_seconds > 26 * 3600";
              for = "10m";
              annotations.summary = "last restic backup on {{ $labels.instance }} is older than 26h";
            }
            {
              alert = "NodeDown";
              expr = ''lag(node_boot_time_seconds{instance=~"${lib.concatStringsSep "|" cfg.alwaysOnHosts}"}[1d]) > 300'';
              annotations.summary = "no metrics from {{ $labels.instance }} for 5 minutes";
            }
          ];
        }
      ];
    };

    systemd.services.alert-ntfy = {
      description = "vmalert to ntfy forwarder";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      environment = {
        NTFY_URL = cfg.ntfyUrl;
        LISTEN_PORT = "9094";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/alert-ntfy.py}";
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    networking.hosts."127.0.0.1" = ["metrics.lab"];

    services.caddy.virtualHosts."https://metrics.lab".extraConfig = ''
      tls internal
      redir / /vmui/
      reverse_proxy localhost:8428
    '';
  };
}
