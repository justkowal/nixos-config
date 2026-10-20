{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.lab.fleetAgent;
  sc = "/run/current-system/sw/bin/systemctl";
  run = pkgs.writeShellScript "fleet-agent-run" ''
    case "$SSH_ORIGINAL_COMMAND" in
      status) ${pkgs.coreutils}/bin/uptime -p; echo "failed units: $(${sc} --failed --no-legend | ${pkgs.coreutils}/bin/wc -l)" ;;
      poweroff|reboot|suspend) exec /run/wrappers/bin/sudo -n ${sc} "$SSH_ORIGINAL_COMMAND" ;;
      update-stage) exec /run/wrappers/bin/sudo -n ${sc} start --no-block nixos-update-stage.service ;;
      update-deploy) exec /run/wrappers/bin/sudo -n ${sc} start --no-block auto-deploy.service ;;
      *) echo "verb not allowed" >&2; exit 1 ;;
    esac
  '';
in {
  options.lab.fleetAgent = {
    publicKey = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "ssh-ed25519 public key of the Pi MCP gateway. Empty keeps the agent off.";
    };
    from = lib.mkOption {
      type = lib.types.str;
      default = "100.113.193.14";
      description = "Only this source address may use the key (the Pi's tailnet IP).";
    };
  };

  config = lib.mkIf (cfg.publicKey != "") {
    users.users.fleet-agent = {
      isSystemUser = true;
      group = "fleet-agent";
      shell = pkgs.bash;
      home = "/var/empty";
      openssh.authorizedKeys.keys = [
        ''restrict,from="${cfg.from}",command="${run}" ${cfg.publicKey}''
      ];
    };
    users.groups.fleet-agent = {};

    security.sudo.extraRules = [
      {
        users = ["fleet-agent"];
        commands = map (c: {
          command = "${sc} ${c}";
          options = ["NOPASSWD"];
        }) [
          "poweroff"
          "reboot"
          "suspend"
          "start --no-block nixos-update-stage.service"
          "start --no-block auto-deploy.service"
        ];
      }
    ];
  };
}
