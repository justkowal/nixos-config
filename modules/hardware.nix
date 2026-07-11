{ config, pkgs, ... }:

{
  # 1. Hardware Firmware (essential for Wi-Fi, Ethernet, and GPU drivers)
  hardware.enableRedistributableFirmware = true;

  # 2. Bluetooth Support
  hardware.bluetooth.enable = true;
  services.blueman.enable = true; # Graphical Bluetooth manager (Blueman)

  # 3. Game Controllers
  hardware.xone.enable = true;      # Xbox One/Series controller drivers (wired and wireless adapter)
  services.joycond.enable = true;   # Nintendo Switch Joy-Con and Pro Controller daemon
  hardware.steam-hardware.enable = true; # Valve controller / Steam deck udev rules

  # 4. OpenRGB (Motherboard/RAM/Peripheral RGB control)
  services.hardware.openrgb = {
    enable = true;
    package = pkgs.openrgb-with-all-plugins;
  };
  # Kernel modules needed for certain motherboard sensors and I2C controllers
  boot.kernelModules = [ "i2c-dev" "i2c-piix4" ];

  # 5. Mouse Customization (libratbag/Piper daemon for gaming mice)
  services.libratbag.enable = true;

  # 6. Printing Services (CUPS printer support)
  services.printing.enable = true;
}
