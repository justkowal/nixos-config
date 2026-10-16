{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.lab.energy;
in {
  imports = [../../modules/tariff.nix];

  options.lab.energy = {
    enable = lib.mkEnableOption "Shelly plug energy exporter pushing to VictoriaMetrics";
    shellyHost = lib.mkOption {
      type = lib.types.str;
      example = "192.168.1.50";
      description = "LAN address of the Shelly Plug S Gen3 on the desktop's power strip (local RPC, auth disabled).";
    };
    deviceName = lib.mkOption {
      type = lib.types.str;
      default = "desktop";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.shelly-exporter = {
      description = "Shelly plug energy exporter";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target" "victoriametrics.service"];
      wants = ["network-online.target"];
      environment = {
        SHELLY_HOST = cfg.shellyHost;
        DEVICE_NAME = cfg.deviceName;
        VM_IMPORT_URL = "http://127.0.0.1:8428/api/v1/import/prometheus";
        TARIFF_JSON = builtins.toJSON {
          inherit (config.lab.tariff) name offPeakWindows pricePeak priceOffPeak;
        };
        PYTHONUNBUFFERED = "1";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/shelly-exporter.py}";
        DynamicUser = true;
        Restart = "always";
        RestartSec = "10s";
      };
    };
  };
}
