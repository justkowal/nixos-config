{config, lib, ...}: let
  cfg = config.lab.rpi4Images;
in {
  options.lab.rpi4Images = {
    enable = lib.mkEnableOption "a writable store for rpi4 SD images built by the local woodpecker agent";
    dir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/rpi4-images";
      readOnly = true;
    };
  };

  config = lib.mkIf cfg.enable {
    # the agent is a DynamicUser, so access goes through a static group instead of an owner
    users.groups.rpi4-images = {};
    systemd.tmpfiles.rules = ["d ${cfg.dir} 2775 root rpi4-images - -"];

    specialisation.worker.configuration = {
      systemd.services.woodpecker-agent-nix.serviceConfig = {
        SupplementaryGroups = ["rpi4-images"];
        ReadWritePaths = [cfg.dir];
      };
    };
  };
}
