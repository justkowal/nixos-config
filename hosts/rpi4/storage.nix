{...}: {
  # existing ext4 disk with personal data on it: mounted as is, never formatted from here.
  # nofail so a missing or slow USB disk cannot block boot.
  fileSystems."/srv/data" = {
    device = "/dev/disk/by-uuid/4d23ec49-7dd2-4802-bc96-fda70ebe7cac";
    fsType = "ext4";
    options = ["nofail" "noatime" "x-systemd.device-timeout=10s"];
  };
}
