{ config, pkgs, ... }:

{
  # Enable Hyprland Window Manager
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  # AMD GPU & Graphics Stack (with modern hardware.graphics config)
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      rocmPackages.clr
      rocmPackages.clr.icd
    ];
  };

  # ROCm environment variable override for RX 6700 XT (gfx1031 -> gfx1030)
  environment.variables = {
    HSA_OVERRIDE_GFX_VERSION = "10.3.0";
  };

  # Flatpak support
  services.flatpak.enable = true;

  # Audio support via Pipewire
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
    # Low latency audio tuning (Default sample rate 48kHz, buffer size 64 frames)
    extraConfig.pipewire = {
      "10-lowlatency" = {
        "context.properties" = {
          "default.clock.rate" = 48000;
          "default.clock.quantum" = 64;
          "default.clock.min-quantum" = 32;
          "default.clock.max-quantum" = 1024;
        };
      };
    };
  };

  # Display login manager (greetd + tuigreet)
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --cmd Hyprland";
        user = "greeter";
      };
    };
  };

  # Security policies
  security.polkit.enable = true;

  # Basic fonts for interface styling
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];
}
