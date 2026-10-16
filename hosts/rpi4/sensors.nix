{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.lab.sensors;
  python = pkgs.python3.withPackages (ps: [ps.smbus2]);
in {
  options.lab.sensors = {
    enable = lib.mkEnableOption "SCD41 + BME280 desk sensors on the rpi4 I2C bus";
    ntfyUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://ntfy.lab/alerts";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.i2c.enable = true;

    systemd.services.desk-sensors = {
      description = "Desk CO2 / climate sensors";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      environment = {
        I2C_BUS = "1";
        SCD41_ADDR = "0x62";
        BME280_ADDR = "0x76";
        VM_IMPORT_URL = "http://127.0.0.1:8428/api/v1/import/prometheus";
        NTFY_URL = cfg.ntfyUrl;
        STATE_FILE = "/run/sensors/latest.json";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        PYTHONUNBUFFERED = "1";
      };
      serviceConfig = {
        ExecStart = "${python}/bin/python3 ${./scripts/sensors.py}";
        DynamicUser = true;
        SupplementaryGroups = ["i2c"];
        RuntimeDirectory = "sensors";
        RuntimeDirectoryMode = "0755";
        Restart = "always";
        RestartSec = "10s";
      };
    };
  };
}
