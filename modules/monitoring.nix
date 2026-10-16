{
  config,
  lib,
  ...
}: let
  cfg = config.lab.monitoring.client;
  host = config.networking.hostName;
in {
  options.lab.monitoring.client = {
    enable = lib.mkEnableOption "node exporter + vmagent shipping metrics to the rpi4";
    remoteWriteUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://nixos-rpi4.lab:8428/api/v1/write";
    };
    textfileDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter-textfile";
      readOnly = true;
      description = "Drop *.prom files here (write to a temp file, then rename) to have them scraped.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      # 9100 is taken by the webhook receiver on the rpi4
      port = 9102;
      enabledCollectors = ["systemd" "textfile"];
      extraFlags = ["--collector.textfile.directory=${cfg.textfileDir}"];
    };

    systemd.tmpfiles.rules = ["d ${cfg.textfileDir} 0755 root root -"];

    services.vmagent = {
      enable = true;
      remoteWrite.url = cfg.remoteWriteUrl;
      prometheusConfig = {
        global.scrape_interval = "30s";
        scrape_configs = [
          {
            job_name = "node";
            static_configs = [
              {
                targets = ["127.0.0.1:9102"];
                labels.instance = host;
              }
            ];
          }
        ];
      };
      extraArgs = [
        "-httpListenAddr=127.0.0.1:8429"
        # unreachable pi buffers ~10 MB/day per host, so 1 GB covers weeks offline
        "-remoteWrite.maxDiskUsagePerURL=1GB"
        "-remoteWrite.label=host=${host}"
      ];
    };
  };
}
