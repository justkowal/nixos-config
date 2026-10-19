{ config, pkgs, ... }:

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
      # Sunshine captures the screen through KMS at the login screen, and Hyprland then fails to take the display
      # ("Could not take device: Device or resource busy"), so Sunshine lets go first. It comes back through
      # sunshine-session-restart once the session is up. The session also sees no Wayland display, so Hyprland
      # never nests inside a headless compositor.
      command = builtins.replaceStrings [ "--cmd Hyprland" ] [ "--cmd 'sh -c \"${config.systemd.package}/bin/systemctl --user stop sunshine.service; exec env WAYLAND_DISPLAY=/nonexistent Hyprland\"'" ] config.lab.greeter.command;
      user = "greeter";
    };
  };

  # the user manager runs from boot without a login so lab-peer and the headless stage (home/lab/peek.nix) answer
  # Peek and Run on desktop on a machine nobody is logged in to. No session, no unlocked screen.
  users.users.justkowal.linger = true;

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
