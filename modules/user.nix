{ pkgs, ... }:

{
  users.users.justkowal = {
    isNormalUser = true;
    description = "justkowal";
    shell = pkgs.nushell;
    extraGroups = [ "networkmanager" "wheel" "video" "render" "docker" "audio" "realtime" ];
  };
}
