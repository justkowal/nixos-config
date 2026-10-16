{
  config,
  lib,
  pkgs,
  ...
}: let
  # ── Flamenco Manager — built from source (upstream does not provide arm64 binaries)
  flamenco = pkgs.callPackage ../../pkgs/flamenco { };


  flamencoManagerConfig = pkgs.writeText "flamenco-manager.yaml" ''
    _meta:
      version: 3
    manager_name: homelab-render
    shared_storage_path: /data/shared-storage
    listen: :8080
    local_manager_storage_path: /data
  '';

  # ponytail: no official Flamenco OCI image — built from upstream binary via dockerTools
  flamencoManagerImage = pkgs.dockerTools.buildImage {
    name = "flamenco-manager";
    tag = "local";
    copyToRoot = pkgs.buildEnv {
      name = "flamenco-manager-root";
      paths = [ flamenco pkgs.cacert ];
    };
    config = {
      Cmd = [ "/bin/flamenco-manager" ];
      WorkingDir = "/data";
    };
  };
in {
  # ── Podman & OCI Containers ────────────────────────────────────────────
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers = {
      portfolio = {
        image = "ghcr.io/justkowal/portfolio:latest";
        ports = [ "3080:3000" ];
        extraOptions = [ "--pull=always" ];
        autoStart = false;
      };

      # ── Flamenco Render Manager ──────────────────────────────────────
      flamenco-manager = {
        imageFile = flamencoManagerImage;
        image = "flamenco-manager:local";
        ports = [ "8080:8080" ];
        volumes = [
          "/var/lib/flamenco:/data"
          "/home/justkowal/Sync/Render:/data/shared-storage"
          "${flamencoManagerConfig}:/data/flamenco-manager.yaml:ro"
        ];
        autoStart = true;
      };
    };
  };
}
