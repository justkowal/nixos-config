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
      # the headless stage (home/lab/peek.nix) owns wayland-0, and a Hyprland that finds a Wayland display nests
      # inside it instead of using the screen, so the session is told there is none
      command = builtins.replaceStrings [ "--cmd Hyprland" ] [ "--cmd 'env WAYLAND_DISPLAY=/nonexistent Hyprland'" ] config.lab.greeter.command;
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
