{ config, lib, pkgs, ... }:

let
  cfg = config.lab.snapshots;
  homeFs = config.fileSystems."/home" or config.fileSystems."/";

  # same naming as btrbk (timestamp_format long) so the GUI parses both hosts alike
  bcachefsSnapshot = pkgs.writeShellApplication {
    name = "lab-bcachefs-snapshot";
    runtimeInputs = [ config.boot.bcachefs.package pkgs.coreutils pkgs.findutils ];
    text = ''
      dir=${lib.escapeShellArg cfg.dir}
      mkdir -p "$dir"
      bcachefs subvolume snapshot -r /home "$dir/home.$(date +%Y%m%dT%H%M)"

      # keep the 24 newest, plus the first snapshot of each of the 7 newest days
      declare -A keep=()
      mapfile -t snaps < <(find "$dir" -mindepth 1 -maxdepth 1 -name 'home.????????T????' -printf '%f\n' | sort)
      n=''${#snaps[@]}
      for ((i = n > 24 ? n - 24 : 0; i < n; i++)); do keep[''${snaps[i]}]=1; done
      declare -A firstOfDay=()
      for s in "''${snaps[@]}"; do
        day=''${s:5:8}
        [ -n "''${firstOfDay[$day]:-}" ] || firstOfDay[$day]=$s
      done
      mapfile -t days < <(printf '%s\n' "''${!firstOfDay[@]}" | sort -r | head -n 7)
      for d in "''${days[@]}"; do keep[''${firstOfDay[$d]}]=1; done

      for s in "''${snaps[@]}"; do
        [ -n "''${keep[$s]:-}" ] || bcachefs subvolume delete "$dir/$s"
      done
    '';
  };
in
{
  options.lab.snapshots = {
    enable = lib.mkEnableOption "hourly /home snapshots (24 hourly, 7 daily) for the time machine GUI";
    dir = lib.mkOption {
      type = lib.types.str;
      default = "/home/.snapshots";
      description = "Snapshot directory. Must be on the same filesystem as /home; /home must be a subvolume.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [{
        assertion = lib.elem homeFs.fsType [ "btrfs" "bcachefs" ];
        message = "lab.snapshots: /home is on ${homeFs.fsType}, only btrfs and bcachefs are supported.";
      }];
      # 0755 so the unprivileged GUI can list snapshots; file modes inside are preserved
      systemd.tmpfiles.rules = [ "d ${cfg.dir} 0755 root root -" ];
    }

    (lib.mkIf (homeFs.fsType == "btrfs") {
      services.btrbk.instances.home = {
        onCalendar = "hourly";
        settings = {
          timestamp_format = "long";
          snapshot_preserve_min = "latest";
          snapshot_preserve = "24h 7d";
          subvolume."/home" = {
            snapshot_dir = cfg.dir;
            snapshot_name = "home";
          };
        };
      };
    })

    (lib.mkIf (homeFs.fsType == "bcachefs") {
      systemd.services.lab-bcachefs-snapshot = {
        description = "Snapshot /home (bcachefs) and prune old snapshots";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe bcachefsSnapshot;
          Nice = 10;
          IOSchedulingClass = "idle";
        };
      };
      systemd.timers.lab-bcachefs-snapshot = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "hourly";
          Persistent = true;
        };
      };
    })
  ]);
}
