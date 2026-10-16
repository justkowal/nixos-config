{
  config,
  pkgs,
  lib,
  laptop ? false,
  ...
}: let
  cfg = config.lab.handoff;

  home-lan = pkgs.writeShellApplication {
    name = "home-lan";
    runtimeInputs = with pkgs; [iproute2 iputils jq tailscale gawk gnused gnugrep coreutils systemd kdePackages.kdeconnect-kde pulseaudio];
    text = ''
      export HOME_LAN_PEER=${lib.escapeShellArg cfg.peer}
      export HOME_LAN_PEER_MAC=${lib.escapeShellArg cfg.peerMac}
      export HOME_LAN_PEER_ADDR=${lib.escapeShellArg cfg.peerAddress}
      export HOME_LAN_KDECONNECT=${lib.escapeShellArg cfg.kdeconnectDevice}
      ${builtins.readFile ./scripts/home-lan.sh}
    '';
  };

  bound = {
    PartOf = ["home-lan.target"];
    After = ["home-lan.target" "graphical-session.target"];
  };
  hl = "${home-lan}/bin/home-lan";
in {
  options.lab.handoff = {
    enable = lib.mkEnableOption "automatic laptop/desktop handoff while both are on the home LAN";

    peer = lib.mkOption {
      type = lib.types.str;
      default =
        if laptop
        then "nixos-desktop"
        else "thinkpad-t14s-gen1-amd";
      description = "Tailscale hostname of the other machine; its LAN endpoints are read from tailscale status.";
    };

    peerMac = lib.mkOption {
      type = lib.types.str;
      default = lib.optionalString laptop "10:ff:e0:40:7d:6e";
      description = "MAC the peer must answer from, so a foreign network with the same subnet does not count as home. Empty skips the check.";
    };

    peerAddress = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "192.168.1.20";
      description = "Fixed LAN address of the peer (DHCP reservation). Empty means discover it.";
    };

    kdeconnectDevice = lib.mkOption {
      type = lib.types.str;
      default = cfg.peer;
      description = "KDE Connect device name of the peer.";
    };

    audioSink.enable = lib.mkEnableOption "PipeWire network sink (laptop plays through the desktop speakers via pulse tunnel on tcp/4713)";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [home-lan];

    systemd.user.targets.home-lan.Unit = {
      Description = "Peer machine reachable on the home LAN";
      After = ["graphical-session.target"];
    };

    systemd.user.services.home-lan-check = {
      Unit.Description = "Check whether ${cfg.peer} is on the LAN";
      Service = {
        Type = "oneshot";
        ExecStart = "${hl} check";
      };
    };

    systemd.user.timers.home-lan-check = {
      Unit.Description = "Poll LAN presence of ${cfg.peer}";
      Timer = {
        OnStartupSec = "20s";
        OnUnitActiveSec = "30s";
        AccuracySec = "5s";
      };
      Install.WantedBy = ["timers.target"];
    };

    # same daemon and ~/.config/lan-mouse/config.toml that lan-mouse-gui manages; the GUI owns the edge layout
    systemd.user.services.home-lan-mouse = {
      Unit = bound // {Description = "lan-mouse while on the home LAN";};
      Service = {
        ExecStart = "${pkgs.lan-mouse}/bin/lan-mouse --daemon";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = ["home-lan.target"];
    };

    systemd.user.services.home-lan-kdeconnect = {
      Unit = bound // {Description = "KDE Connect clipboard and notification sync with ${cfg.kdeconnectDevice}";};
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${hl} kdeconnect on";
        ExecStop = "${hl} kdeconnect off";
      };
      Install.WantedBy = ["home-lan.target"];
    };

    systemd.user.services.home-lan-audio = lib.mkIf cfg.audioSink.enable {
      Unit = bound // {Description = "PipeWire network audio with ${cfg.peer}";};
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${hl} audio ${if laptop then "sender" else "receiver"} start";
        ExecStop = "${hl} audio ${if laptop then "sender" else "receiver"} stop";
      };
      Install.WantedBy = ["home-lan.target"];
    };
  };
}
