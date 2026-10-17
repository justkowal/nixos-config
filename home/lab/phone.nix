{
  config,
  lib,
  ...
}: let
  cfg = config.lab.phone;
in {
  options.lab.phone = {
    enable = lib.mkEnableOption "the phone app: a small web app served by labd on this machine's tailnet address only";
    port = lib.mkOption {
      type = lib.types.port;
      default = 8765;
    };
    bind = lib.mkOption {
      type = lib.types.str;
      default = "tailscale";
      description = "`tailscale` for this machine's tailnet IPv4, or one explicit address. Listening on every interface is refused.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."lab/phone.json".text = builtins.toJSON {
      enable = true;
      inherit (cfg) port bind;
    };

    lab.palette.entries = [
      {
        title = "Phone app: copy the token";
        group = "Phone";
        exec = "lab phone --copy";
      }
    ];
  };
}
