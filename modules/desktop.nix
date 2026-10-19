{ config, pkgs, ... }:

let
  # marker for lab-autolock, only the automatic login gets a locked screen
  autologinSession = pkgs.writeShellScript "lab-autologin-session" ''
    touch "$XDG_RUNTIME_DIR/lab-autologin"
    exec Hyprland
  '';
in
{
  imports = [ ./lab-greeter.nix ./lab-splash.nix ];

  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [ rocmPackages.clr rocmPackages.clr.icd ];
  };

  # RX 6700 XT (gfx1031) needs gfx1030 override for ROCm
  environment.variables.HSA_OVERRIDE_GFX_VERSION = "10.3.0";

  # Blender HIP detection
  systemd.tmpfiles.rules = [ "L+ /opt/rocm/hip - - - - ${pkgs.rocmPackages.clr}" ];

  services.flatpak.enable = true;
  programs.kdeconnect.enable = true;

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = "*";
  };


  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
    extraConfig.pipewire."10-lowlatency" = {
      "context.properties" = {
        "default.clock.rate" = 48000;
        "default.clock.allowed-rates" = [ 44100 48000 88200 96000 ];
        "default.clock.quantum" = 64;
        "default.clock.min-quantum" = 32;
        "default.clock.max-quantum" = 1024;
      };
    };
  };

  services.greetd = {
    enable = true;
    settings.default_session = {
      command = config.lab.greeter.command;
      user = "greeter";
    };

    # first login after a boot is automatic so lab-peer exists for Run on desktop and Peek, the session
    # comes up locked (lab-autolock below). Later logins after a logout use the greeter.
    settings.initial_session = {
      command = "${autologinSession}";
      user = "justkowal";
    };
  };

  systemd.user.services.lab-autolock = {
    description = "Lock the screen of an automatic login";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    unitConfig.ConditionPathExists = "%t/lab-autologin";
    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f %t/lab-autologin";
      ExecStart = "${pkgs.hyprlock}/bin/hyprlock --grace 0";
    };
  };

  security.polkit.enable = true;
  security.pam.services.greetd.enableGnomeKeyring = true;
  security.pam.services.hyprlock = {};

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];

  environment.systemPackages = with pkgs; [
    xdg-terminal-exec
  ];
}
