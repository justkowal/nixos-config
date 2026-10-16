{ pkgs, ... }:

{
  users.users.justkowal = {
    isNormalUser = true;
    description = "justkowal";
    shell = pkgs.nushell;
    extraGroups = [ "networkmanager" "wheel" "video" "render" "docker" "audio" "realtime" "input" "uinput" "i2c" ];
  };

  # ddcutil brightness on external monitors needs /dev/i2c-* without root
  hardware.i2c.enable = true;
  boot.kernelModules = [ "i2c-dev" ];
}
