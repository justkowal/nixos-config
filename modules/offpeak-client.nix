{config, lib, pkgs, ...}: let
  cfg = config.lab.offpeak;
  user = "justkowal";

  submit = pkgs.writeShellApplication {
    name = "offpeak-submit";
    runtimeInputs = [pkgs.coreutils pkgs.curl pkgs.jq];
    text = ''
      usage() {
        echo "usage: offpeak-submit [-d DEADLINE] NAME COMMAND..." >&2
        echo "  DEADLINE: anything date -d understands, e.g. 'tomorrow 07:00'" >&2
        exit 2
      }
      deadline=null
      while getopts d:h opt; do
        case "$opt" in
          d) deadline=$(date -d "$OPTARG" +%s) ;;
          *) usage ;;
        esac
      done
      shift $((OPTIND - 1))
      [ $# -ge 2 ] || usage
      name=$1
      shift
      jq -nc --arg name "$name" --arg command "$*" --argjson deadline "$deadline" \
        '{name: $name, command: $command, deadline: $deadline}' |
        curl -fsS -m 15 -X POST \
          -H "Content-Type: application/json" \
          -H @<(printf 'X-Offpeak-Token: %s\n' "$(cat ${config.sops.secrets."offpeak_submit_token".path})") \
          --data-binary @- \
          http://nixos-rpi4.lab:9100/hooks/offpeak-submit
    '';
  };
in {
  options.lab.offpeak = {
    submit.enable = lib.mkEnableOption "the offpeak-submit helper for the rpi4 job spool";
    runner = {
      enable = lib.mkEnableOption "the restricted offpeak user that runs spooled jobs on this host";
      authorizedKey = lib.mkOption {
        type = lib.types.str;
        description = "Public half of the rpi4's offpeak_ssh_key.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.submit.enable {
      sops.secrets."offpeak_submit_token".owner = user;
      environment.systemPackages = [submit];
    })

    (lib.mkIf cfg.runner.enable {
      # no wheel, no docker: jobs get plain user rights plus the nix daemon
      users.users.offpeak = {
        isSystemUser = true;
        group = "offpeak";
        home = "/var/lib/offpeak";
        createHome = true;
        useDefaultShell = true;
        openssh.authorizedKeys.keys = [
          ''restrict,from="${config.lab.dnsMapping."nixos-rpi4.lab"}" ${cfg.runner.authorizedKey}''
        ];
      };
      users.groups.offpeak = {};
    })
  ];
}
