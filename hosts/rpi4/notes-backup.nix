{
  config,
  lib,
  pkgs,
  ...
}: let
  state = "/home/justkowal/.local/state/notes-backup";
in {
  # the age private key is not on the Pi on purpose: only the public recipient is, so snapshots cannot be read here
  systemd.services.notes-backup = {
    description = "Encrypted snapshot of the notes vault to a private github repo";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    onFailure = ["backup-failed-ntfy@%n.service"];
    path = with pkgs; [git age zstd gnutar openssh coreutils];
    environment = {
      VAULT = "/home/justkowal/Sync/Notes/Everything";
      STATE = state;
      RECIPIENT = "age137qlj9mtd4nyk9x8908uzmp5hkz4f0fcehw38m9j0l3glzy5zexqrfe25x";
      REPO = "git@github.com:justkowal/notes-backup.git";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "justkowal";
      ExecStart = "${pkgs.bash}/bin/bash ${./scripts/notes-backup.sh}";
      Nice = 15;
    };
  };

  systemd.timers.notes-backup = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 03:40:00";
      Persistent = true;
      RandomizedDelaySec = "10min";
    };
  };
}
