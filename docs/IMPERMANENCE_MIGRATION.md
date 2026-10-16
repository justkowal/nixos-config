# Impermanence migration (roadmap item 7)

`modules/impermanence.nix` wipes `/` on every boot. It does nothing until all of these hold:

1. `lab.impermanence.enable = true`
2. `lab.impermanence.iUnderstandRootIsWiped = true` (assertion fails otherwise)
3. `lab.impermanence.layout` describes the migrated layout below (assertion fails if null)
4. At boot, the initrd finds `@root`, `@root-blank`, `@persist` on the device **and** the marker
   `/persist/.lab-impermanence-armed`. Without the marker the rollback service logs
   `not armed` and leaves `/` alone.

Step 4 means the first boots on the new layout never wipe anything. You arm it by hand after
checking `lab-impermanence-diff`.

## Target layout

Same layout for both hosts, subvolumes at the top level of the filesystem:

| Subvolume     | Mounted at | Contents                                                    |
|---------------|------------|-------------------------------------------------------------|
| `@root`       | `/`        | recreated from `@root-blank` every armed boot               |
| `@root-blank` | (none)     | read-only snapshot of an empty `@root`                      |
| `@nix`        | `/nix`     | the Nix store. Must not live in `@root` or it is wiped too  |
| `@persist`    | `/persist` | everything listed in `environment.persistence."/persist"`   |
| `@home`       | `/home`    | home directories, never wiped, snapshotted by item 8        |
| `@old_roots`  | (none)     | created by the rollback: the last 5 discarded roots         |

btrfs mounts these with `subvol=@x`. bcachefs has no `subvol=` mount option, so the module
uses util-linux `X-mount.subdir=@x` (see Limitations).

`/persist`, `/home` and `/nix` are `neededForBoot`: sops reads the age key from
`/home/justkowal/.config/sops/age/keys.txt` and the ssh host key during activation.

## What is persisted

Generated from the host config, check the real list with:

```
nix eval .#nixosConfigurations.laptop.config.environment.persistence --apply 'p: map (d: d.directory) p."/persist".directories'
```

(only after enabling the module). Always: `/var/log`, `/var/lib/nixos`, `/var/lib/systemd`,
`/var/lib/private` (DynamicUser state: ollama models), `/root/.ssh`, `/var/db/sudo`,
`/etc/machine-id`, the openssh host keys (`/etc/ssh/ssh_host_*`). Per service when enabled:
NetworkManager connections, tailscale, bluetooth, fprint, fwupd, tlp, upower, flatpak, cups,
linux-enable-ir-emitter, OpenRGB, `/etc/lact` (when `services.lact.settings` is empty),
docker (laptop only, desktop docker has its own disk), podman `/var/lib/containers`,
libvirt, flamenco-worker (desktop worker specialisation), `/var/lib/sops-nix` (only if the
age key lives there) and the lanzaboote PKI bundle `/var/lib/sbctl` (laptop: losing it means
re-enrolling Secure Boot keys).

Not persisted on purpose: woodpecker agents (DynamicUser, no state directory; if that
changes their state lands in `/var/lib/private`), `/var/cache`, `/var/tmp`.

Passwords: `/etc/shadow` is regenerated every boot, so the module sets
`users.mutableUsers = false` and `hashedPasswordFile = /persist/passwords/justkowal`.
`passwd` stops working; change the password by rewriting that file (`mkpasswd -m yescrypt`).
root keeps whatever the host config says (locked by default, use sudo).

Add host specific paths in the host config:

```nix
environment.persistence."/persist".directories = [ "/var/lib/something" ];
```

## Before you start

- A fresh restic backup of both hosts (roadmap prereq), and verify you can list it.
- A NixOS ISO on a USB stick (`nix build .#nixosConfigurations.iso.config.system.build.isoImage`).
- The LUKS passphrase for the laptop (the ISO cannot use the TPM2 binding).
- Run the "what would be lost" listing on the **current** system, before touching anything:

  ```
  nix build .#nixosConfigurations.laptop.config.system.build.labImpermanenceDiff
  sudo ./result/bin/lab-impermanence-diff | less
  ```

  (this needs `modules/impermanence.nix` imported; it is buildable while disabled). Anything it
  lists that you want to keep goes into `environment.persistence` first.

## Step 1: build the new generation without activating it

In the host config:

```nix
# laptop
lab.impermanence = {
  enable = true;
  iUnderstandRootIsWiped = true;
  layout = {
    fsType = "btrfs";
    device = "/dev/mapper/cryptroot";
    mountOptions = [ "compress=zstd" "noatime" "discard=async" ];
  };
};

# desktop
lab.impermanence = {
  enable = true;
  iUnderstandRootIsWiped = true;
  layout = {
    fsType = "bcachefs";
    device = "/dev/disk/by-uuid/91169176-2eea-4719-8327-2e0bbc3cc0c1";
    mountOptions = [ "noatime" ];
  };
};
```

Then `sudo nixos-rebuild boot --flake .#<host>`. Use `boot`, never `switch`: the new fstab
points at subvolumes that do not exist yet. Do not reboot into it yet.

## Step 2a: migrate the laptop (btrfs), from the ISO

```
cryptsetup open /dev/disk/by-partuuid/31a0a789-2f9e-499c-91a6-76bc90aef8b9 cryptroot
mount -o subvolid=5 /dev/mapper/cryptroot /mnt
cd /mnt

btrfs subvolume create @root
btrfs subvolume create @nix
btrfs subvolume create @persist
btrfs subvolume create @home
btrfs subvolume snapshot -r @root @root-blank      # while @root is still empty

# mv across subvolumes is a copy, reflinks make it instant and free
cp -a --reflink=always nix/.  @nix/
cp -a --reflink=always home/. @home/

mkdir -p @persist/etc/ssh @persist/var/lib @persist/var/db @persist/root @persist/etc/NetworkManager
cp -a etc/ssh/ssh_host_* @persist/etc/ssh/
cp -a etc/machine-id     @persist/etc/
cp -a --reflink=always etc/NetworkManager/system-connections @persist/etc/NetworkManager/
cp -a --reflink=always var/log @persist/var/
cp -a --reflink=always root/.ssh @persist/root/ 2>/dev/null || true
cp -a --reflink=always var/db/sudo @persist/var/db/ 2>/dev/null || true
for d in nixos systemd private tailscale bluetooth fprint fwupd tlp upower flatpak \
         linux-enable-ir-emitter docker containers sbctl; do
  [ -e var/lib/$d ] && cp -a --reflink=always var/lib/$d @persist/var/lib/
done

install -d -m 700 @persist/passwords
grep '^justkowal:' etc/shadow | cut -d: -f2 > @persist/passwords/justkowal
chmod 600 @persist/passwords/justkowal
test -s @persist/passwords/justkowal && echo password ok

cd /; umount /mnt; reboot
```

Leave the old top-level files where they are for now. The previous generation in the boot
menu still mounts the top level as `/` and boots the old system unchanged.

## Step 2b: migrate the desktop (bcachefs), from the ISO

The ISO kernel must have the bcachefs module (out of tree since Linux 6.18). The repo ISO
ships bcachefs-tools; check `modprobe bcachefs` works before starting.

```
mount -t bcachefs /dev/disk/by-uuid/91169176-2eea-4719-8327-2e0bbc3cc0c1 /mnt
cd /mnt

bcachefs subvolume create @root
bcachefs subvolume create @nix
bcachefs subvolume create @persist
bcachefs subvolume create @home
bcachefs subvolume snapshot -r @root @root-blank

cp -a --reflink=auto nix/.  @nix/
cp -a --reflink=auto home/. @home/
```

`--reflink=auto` falls back to a real copy if bcachefs refuses a cross subvolume reflink, so
check free space first (`df -h /mnt`, the store plus home must fit twice in the worst case).
Then the same persist copies as the laptop, with this directory list:

```
for d in nixos systemd private tailscale bluetooth flatpak cups OpenRGB containers flamenco-worker; do
  [ -e var/lib/$d ] && cp -a --reflink=auto var/lib/$d @persist/var/lib/
done
mkdir -p @persist/etc && cp -a etc/lact @persist/etc/ 2>/dev/null || true
```

plus ssh host keys, machine-id, NetworkManager connections, `/var/log`, `/root/.ssh`,
`/var/db/sudo` and the password file exactly as in 2a. `/var/lib/docker` is its own disk and
is not touched.

## Step 3: first boot on the new layout (not armed)

Boot the new generation. The initrd logs `not armed ... NOT wiping /`. Check:

```
findmnt / /nix /persist /home        # sources show [/@root], [/@nix], ...
ls /run/secrets                      # sops decrypted with the persisted host key
sudo -k; sudo true                   # password file works
tailscale status; nmcli connection
sudo lab-impermanence-diff
```

Everything under "on / but neither persisted nor ephemeral" is deleted on the first armed
boot. Persist what matters (host config), rebuild, run it again until the list is only junk.

## Step 4: arm

```
sudo touch /persist/.lab-impermanence-armed
sudo reboot
```

After this boot `/` is a fresh copy of `@root-blank`. The previous root is kept in
`@old_roots/<UTC timestamp>` (last 5 boots).

## Recovery

- Stop wiping: `sudo rm /persist/.lab-impermanence-armed` (takes effect next boot).
- Get a file back from a discarded root:
  - laptop: `sudo mount -o subvolid=5 /dev/mapper/cryptroot /mnt; ls /mnt/@old_roots`
  - desktop: `sudo mount -t bcachefs -o X-mount.subdir=@old_roots /dev/disk/by-uuid/9116... /mnt`
- Undo the migration entirely: boot the pre-migration generation from the boot menu; it
  mounts the untouched top level. Only delete the old top-level `nix`, `home`, `etc`, `var`
  copies once you have run armed for a while.

## Limitations

- bcachefs: no native `subvol=` mount option. `X-mount.subdir` is marked EXPERIMENTAL in
  `mount(8)` (util-linux 2.42). It was verified in a NixOS VM test with bcachefs-tools 1.39.6:
  `/`, `/nix`, `/persist`, `/home` mounted from one device, rollback wipes `/`, persisted files,
  machine-id, ssh host key and password survive, disarmed boots keep `/`. Same test passes for
  btrfs.
- bcachefs: `bcachefs subvolume delete` does not recurse, so pruning an old root that contains
  nested subvolumes fails (logged, boot continues). Space from deleted snapshots is reclaimed
  asynchronously.
- bcachefs is out of tree since Linux 6.18. A kernel without a matching module cannot mount
  `/` regardless of this module.
- During one experiment a second plain (non subdir) mount of the bcachefs device, while it was
  already mounted, hung. The rollback service unmounts its top-level mount before
  `sysroot.mount`. At runtime, inspect subvolumes with `X-mount.subdir`, as above.
- btrfs: subvolumes systemd creates under `/var/lib/machines` or `/var/lib/portables` are
  removed with the old root (`btrfs subvolume delete --recursive`).
- `users.mutableUsers = false` is forced while armed or not, as long as the module is enabled.
