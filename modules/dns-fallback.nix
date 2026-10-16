{config, lib, ...}: let
  cfg = config.lab.dnsFallback;
in {
  options.lab.dnsFallback = {
    enable = lib.mkEnableOption "blocky on the rpi4 as primary resolver with public fallbacks for when the Pi is down";
    primary = lib.mkOption {
      type = lib.types.str;
      default = config.lab.dnsMapping."nixos-rpi4.lab";
      defaultText = lib.literalExpression ''config.lab.dnsMapping."nixos-rpi4.lab"'';
    };
    fallback = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["1.1.1.1" "9.9.9.9"];
    };
  };

  config = lib.mkIf cfg.enable {
    # MagicDNS (100.100.100.100) only forwards to the Pi, so it dies with it; glibc's own failover is what survives
    services.tailscale.extraSetFlags = ["--accept-dns=false"];

    # glibc reads at most 3 servers; blocked domains get an answer from blocky, so only a dead Pi falls through
    networking.nameservers = lib.mkForce ([cfg.primary] ++ cfg.fallback);
    networking.search = ["lab"];
    networking.resolvconf.extraOptions = ["timeout:1" "attempts:2"];
  };
}
