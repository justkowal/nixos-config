{config, lib, pkgs, ...}: let
  cfg = config.lab.offpeak;
  state = "/var/lib/offpeak";
  queue = "${state}/queue";
  host = "nixos-desktop.lab";
  ntfy = "http://127.0.0.1:2586/offpeak";

  toMin = s: let
    p = lib.splitString ":" s;
  in
    lib.toIntBase10 (lib.elemAt p 0) * 60 + lib.toIntBase10 (lib.elemAt p 1);
  windows = lib.concatMapStringsSep " " (w: "${toString (toMin w.start)}-${toString (toMin w.end)}") config.lab.tariff.offPeakWindows;

  submit = pkgs.writeShellScript "offpeak-submit-hook" ''
    set -eu
    PATH=${lib.makeBinPath [pkgs.coreutils pkgs.jq]}
    if [ -z "''${OFFPEAK_TOKEN:-}" ] || [ "$OFFPEAK_TOKEN" != "$(cat ${config.sops.secrets."offpeak_submit_token".path})" ]; then
      echo "unauthorized"
      exit 1
    fi
    job=$(printf '%s' "''${OFFPEAK_PAYLOAD:-}" | jq -ce '
      select((.name | type) == "string" and (.name | length) > 0
        and (.command | type) == "string" and (.command | length) > 0
        and ((.deadline | type) == "number" or .deadline == null))
      | {name, command, deadline: (.deadline | if . == null then null else floor end)}') || {
      echo "bad job, expected {name, command, deadline: unix epoch or null}"
      exit 1
    }
    safe=$(printf '%s' "$job" | jq -r .name | tr -c 'A-Za-z0-9._-' '_' | cut -c1-40)
    f="$(date +%s%N)-$safe.json"
    printf '%s\n' "$job" > "${queue}/.$f"
    mv "${queue}/.$f" "${queue}/$f"
    echo "queued $f"
  '';

  run = pkgs.writeShellScript "offpeak-run" ''
    set -u
    PATH=${lib.makeBinPath [pkgs.coreutils pkgs.jq pkgs.curl pkgs.netcat pkgs.openssh]}
    shopt -s nullglob

    notify() { curl -fsS -m 10 -H "Title: $1" -H "Priority: $2" --data-binary @- ${ntfy} >/dev/null || true; }

    jobs=(${queue}/*.json)
    [ ''${#jobs[@]} -eq 0 ] && exit 0

    now=$(date +%s)
    mins=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
    go=0
    for w in ${windows}; do
      s=''${w%-*} e=''${w#*-}
      if [ "$s" -le "$e" ]; then
        [ "$mins" -ge "$s" ] && [ "$mins" -lt "$e" ] && go=1
      else
        { [ "$mins" -ge "$s" ] || [ "$mins" -lt "$e" ]; } && go=1
      fi
    done
    for j in "''${jobs[@]}"; do
      d=$(jq -r '.deadline // empty' "$j")
      [ -n "$d" ] && [ "$d" -le $(( now + ${toString (cfg.deadlineLeadMinutes * 60)} )) ] && go=1
    done
    if [ "$go" -eq 0 ]; then
      echo "''${#jobs[@]} job(s) waiting for the next off-peak window"
      exit 0
    fi

    if ! nc -z -w 2 ${host} 22; then
      curl -fsS -m 10 -X POST http://127.0.0.1:9100/hooks/wake-worker || true
      start=$(date +%s)
      until nc -z -w 2 ${host} 22; do
        if [ $(( $(date +%s) - start )) -ge ${toString cfg.bootTimeout} ]; then
          echo "desktop did not answer ssh within ${toString cfg.bootTimeout}s, ''${#jobs[@]} job(s) stay queued" | notify "offpeak: desktop unreachable" high
          exit 1
        fi
        sleep 5
      done
      # the boot router may still be switching into the worker specialisation
      sleep 60
    fi

    while :; do
      jobs=(${queue}/*.json)
      [ ''${#jobs[@]} -eq 0 ] && break
      j=''${jobs[0]}
      name=$(jq -r .name "$j")
      cmd=$(jq -r .command "$j")
      # one attempt per job, so a broken job cannot loop forever
      rm -f "$j"
      echo "running $name"
      t0=$(date +%s)
      out=$(ssh -i ${config.sops.secrets."offpeak_ssh_key".path} \
        -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15 -o ServerAliveInterval=60 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${state}/known_hosts \
        offpeak@${host} -- "$cmd" 2>&1)
      rc=$?
      took=$(( $(date +%s) - t0 ))
      printf '%s\n' "$out"
      if [ "$rc" -eq 0 ]; then
        printf 'done in %ss\n%s\n' "$took" "$(printf '%s' "$out" | tail -c 2000)" | notify "offpeak: $name ok" default
      else
        printf 'exit %s after %ss\n%s\n' "$rc" "$took" "$(printf '%s' "$out" | tail -c 2000)" | notify "offpeak: $name failed" high
      fi
    done
  '';
in {
  imports = [../../modules/tariff.nix];

  options.lab.offpeak = {
    enable = lib.mkEnableOption "the off-peak job spool that runs queued commands on the desktop worker";
    deadlineLeadMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Run outside off-peak hours once a job's deadline is this close.";
    };
    bootTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.offpeak = {
      isSystemUser = true;
      group = "offpeak";
      home = state;
    };
    users.groups.offpeak = {};
    # the webhook receiver drops jobs into the queue
    users.users.webhook.extraGroups = ["offpeak"];

    systemd.tmpfiles.rules = [
      "d ${state} 0750 offpeak offpeak - -"
      "d ${queue} 2770 offpeak offpeak - -"
    ];

    sops.secrets."offpeak_submit_token".owner = "webhook";
    sops.secrets."offpeak_ssh_key".owner = "offpeak";

    lab.webhookHooks = [
      {
        id = "offpeak-submit";
        execute-command = toString submit;
        http-methods = ["POST"];
        include-command-output-in-response = true;
        include-command-output-in-response-on-error = true;
        pass-environment-to-command = [
          {
            source = "header";
            name = "X-Offpeak-Token";
            envname = "OFFPEAK_TOKEN";
          }
          {
            source = "entire-payload";
            envname = "OFFPEAK_PAYLOAD";
          }
        ];
      }
    ];

    systemd.services.offpeak-run = {
      description = "Run queued off-peak jobs on the desktop worker";
      after = ["network-online.target" "webhook-receiver.service"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "offpeak";
        Group = "offpeak";
        ExecStart = toString run;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [state];
      };
    };

    systemd.timers.offpeak-window = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = map (w: "*-*-* ${w.start}:00") config.lab.tariff.offPeakWindows;
        Unit = "offpeak-run.service";
      };
    };

    # catches deadlines and jobs submitted mid-window
    systemd.timers.offpeak-poll = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*:0/15";
        Unit = "offpeak-run.service";
      };
    };
  };
}
