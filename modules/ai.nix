{ config, pkgs, ... }:

{
  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;
    environmentVariables = {
      HSA_OVERRIDE_GFX_VERSION = "10.3.0";
      HIP_VISIBLE_DEVICES = "0";
      OLLAMA_FLASH_ATTENTION = "1";
      OLLAMA_NUM_PARALLEL = "4";
    };
    rocmOverrideGfx = "10.3.0";
    # loadModels removed to prevent pre-loading into RAM/VRAM
  };

  users.users.ollama = {
    isSystemUser = true;
    group = "ollama";
    extraGroups = [ "render" "video" ];
  };
  users.groups.ollama = {};

  environment.systemPackages = with pkgs; [
    oterm
    poppler-utils
    inotify-tools
  ];
}
