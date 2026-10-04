{ lib, ... }:

{
  programs.dconf.enable = true;
  programs.ssh.startAgent = true;

  services.openssh = {
    enable = true;
    startWhenNeeded = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "no";
    };
  };

  services.gnome.evolution-data-server.enable = true;
  services.gnome.gnome-online-accounts.enable = true;
  services.gnome.gnome-keyring.enable = true;
  services.gnome.gcr-ssh-agent.enable = false;

  services.gvfs.enable = true;
  services.tumbler.enable = true;
  services.udisks2.enable = true;

  virtualisation.docker = {
    enable = true;
    enableOnBoot = lib.mkDefault false;
  };

  virtualisation.podman.enable = true;
}
