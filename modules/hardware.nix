{ config, pkgs, ... }:

{
  # Unlock GPU overclocking/undervolting
  boot.kernelParams = [ "amdgpu.ppfeaturemask=0xffffffff" ];

  hardware.enableRedistributableFirmware = true;

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  hardware.xone.enable = true;
  services.joycond.enable = true;
  hardware.steam-hardware.enable = true;

  services.hardware.openrgb = {
    enable = true;
    package = pkgs.openrgb-with-all-plugins;
  };
  boot.kernelModules = [ "i2c-dev" "i2c-piix4" ];

  services.ratbagd.enable = true;

  services.printing = {
    enable = true;
    startWhenNeeded = true;
  };
}
