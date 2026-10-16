{ config, lib, ... }:

let
  # tailnet addresses; the first name of each host is its networking.hostName
  hosts = {
    "100.113.193.14" = [
      "nixos-rpi4"
      "nixos-rpi4.lab"
      "lab"
      "home.lab"
      "bookmarks.lab"
      "docs.lab"
      "idm.lab"
      "git.lab"
      "ci.lab"
      "render.lab"
      "portfolio.lab"
      "vault.lab"
      "ntfy.lab"
      "status.lab"
      "cache.lab"
    ];
    "100.109.222.110" = [ "nixos-desktop" "nixos-desktop.lab" ];
    "100.69.154.81" = [ "thinkpad-t14s-gen1-amd" "thinkpad-t14s-gen1-amd.lab" ];
  };

  isSelf = names: builtins.head names == config.networking.hostName;
in
{
  options.lab.dnsMapping = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    readOnly = true;
    description = "Every *.lab name mapped to its tailnet address, for the rpi4's blocky.";
  };

  config = {
    lab.dnsMapping = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList
      (ip: names: map (n: lib.nameValuePair n ip) (lib.filter (n: n == "lab" || lib.hasSuffix ".lab" n) names))
      hosts));

    networking.hosts = lib.filterAttrs (_: names: !isSelf names) hosts;
  };
}
