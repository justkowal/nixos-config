# rpi4 recovery runbook

Target: a dead SD card or Pi is about an hour of downtime. Everything the Pi runs is declared in this repo; what has to come back from elsewhere is the SSH host key (sops depends on it), service state, and the internal CA key.

## What breaks while the Pi is down

| Thing | Behaviour |
| :--- | :--- |
| `*.lab` names on desktop/laptop | Keep working: `modules/lab-hosts.nix` writes them into `/etc/hosts`, no DNS involved. |
| Internet DNS | Works only with `lab.dnsFallback.enable` (blocky first, then 1.1.1.1 / 9.9.9.9 after a 1 s timeout). Without it, desktop/laptop use Tailscale MagicDNS, which forwards to the Pi and fails. |
| Nix substitution from cache.lab | `fallback = true` and `connect-timeout = 3`, builds continue from cache.nixos.org / locally. |
| Desktop boot | The boot router times out and stays in desktop mode. |
| Kanidm logins (desktop) | Only accounts that logged in online before still authenticate, from the kanidm-unixd cache. See the note below. Local accounts (justkowal, root) are unaffected. |
| restic.lab, ntfy, CI, git, vault, paperless | Down until restored. |

### kanidm-unixd offline cache (checked 2026-10-16)

- Desktop (and rpi4) import `modules/kanidm-client.nix`; the laptop does not use kanidm at all, so nothing to cache there.
- The module sets `cache_db = "/var/cache/kanidm-unixd/cache.db"`, but kanidm 1.11's unixd config key is `cache_db_path` (confirmed from the field list in the `kanidm_unixd` binary). The line is ignored, so unixd uses its built-in default path under `/var/cache/kanidm-unixd/`. Offline auth still works, because it is on by default and does not depend on that key. Fix it by renaming the key to `cache_db_path`, or delete the line.
- Offline auth only covers accounts that logged in successfully while idm.lab was reachable, and only until `cache_timeout` runs out. Not yet tested by actually pulling the Pi: do that during the item 2 drill.

## 0. What you need

- A machine with this repo and the admin age key (desktop: `~/.ssh/id_ed25519`, converted with `ssh-to-age`, listed first in `.sops.yaml`).
- A new SD card or the USB SSD, and a card reader.
- One of:
  - the latest image from the desktop: `/var/lib/rpi4-images/latest.img.zst` (written by `.woodpecker/sd-image.yaml`, newest 3 kept), or
  - a fresh build: `nix build .#nixosConfigurations.rpi4.config.system.build.sdImage` (desktop and laptop both emulate aarch64; slow without cache.lab).
- State, newest first:
  - `~/Sync/Backups/state/homelab-state-*.tar.zst` and `~/Sync/Backups/forgejo/` on the desktop or laptop (Syncthing copies; kanidm, woodpecker, Caddy PKI including the CA key, vaultwarden),
  - the off-site restic repository (`lab.backup.offsite`: paperless, vaultwarden, kanidm, the Sync/Backups tree),
  - `https://restic.lab` holds only the desktop and laptop repositories and lives on the Pi itself. It is not a source for the Pi's own state, and if its disk died, those repositories are gone too. Re-run their first backup once the Pi is back.

## 1. Flash

```sh
lsblk                                  # find the card, e.g. /dev/sdX; double-check, dd overwrites without asking
zstdcat /var/lib/rpi4-images/latest.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Do not boot it yet when you have the old host key (next step). Booting first generates a new host key, and sops then cannot decrypt anything.

## 2. Restore the SSH host key (sops identity)

sops-nix on the Pi decrypts with `/etc/ssh/ssh_host_ed25519_key` (`age.sshKeyPaths`). The second recipient in `.sops.yaml` is that key's age form.

### a) You have the old key

The old key may be in a backup, or the old SD may still be readable. Mount the new card's root (`NIXOS_SD` label) and copy it in:

```sh
sudo mount /dev/disk/by-label/NIXOS_SD /mnt
sudo install -d -m 0755 /mnt/etc/ssh
sudo install -m 0600 ssh_host_ed25519_key     /mnt/etc/ssh/
sudo install -m 0644 ssh_host_ed25519_key.pub /mnt/etc/ssh/
sudo umount /mnt
```

### b) The key is lost

Boot once, let it generate a new key, then re-encrypt for it from the desktop:

```sh
ssh-keyscan -t ed25519 nixos-rpi4.lab | ssh-to-age   # new recipient
# replace the second age recipient in .sops.yaml with it
sops updatekeys hosts/rpi4/secrets/secrets.yaml
```

Commit, deploy (step 4), and update `programs.ssh.knownHosts."nixos-rpi4.lab"` in `hosts/desktop/configuration.nix` (the CI cache push pins it). Remove the old entry from `~/.ssh/known_hosts` on the clients.

Save a copy of the host key somewhere offline (the vault, or encrypted next to the admin key) so next time is path a).

## 3. Boot and rejoin

Insert the card and power on. It joins the tailnet with `tailscale_auth_key` from sops. If the auth key has expired, create a new one in the Tailscale admin console and update the secret first. In the admin console, delete the old `nixos-rpi4` node if the new one came up as `nixos-rpi4-1`, then rename it. The tailnet IP in `modules/lab-hosts.nix` (`100.113.193.14`) must still match. If it changed, update that file and redeploy desktop and laptop.

## 4. Deploy the current config

The image is whatever commit CI built. Bring it up to date from the desktop:

```sh
nixos-rebuild switch --flake .#rpi4 --target-host justkowal@nixos-rpi4.lab --use-remote-sudo
```

## 5. Restore state

Stop the services first, then put the data back:

```sh
sudo systemctl stop kanidm woodpecker-server vaultwarden paperless-web paperless-scheduler paperless-consumer forgejo caddy
```

From the Syncthing state archive (copy it over from the desktop):

```sh
mkdir /tmp/state && zstdcat homelab-state-*.tar.zst | tar -C /tmp/state -x
sudo install -m 0600 -o kanidm -g kanidm /tmp/state/kanidm/kanidm.db /var/lib/kanidm/kanidm.db
sudo cp /tmp/state/kanidm/*.pem /var/lib/kanidm/ && sudo chown kanidm:kanidm /var/lib/kanidm/*.pem
sudo install -m 0600 -o caddy -g caddy /tmp/state/caddy-pki/* /var/lib/caddy/pki/
sudo install -m 0600 -o vaultwarden -g vaultwarden /tmp/state/vaultwarden/* /var/lib/vaultwarden/
sudo install -D -m 0600 /tmp/state/woodpecker/woodpecker.sqlite /var/lib/private/woodpecker-server/woodpecker.sqlite
```

The Caddy CA key matters most. With it gone, every client has to trust a new `modules/certs/homelab-ca.crt`.

From off-site restic (paperless, plus anything newer than the archive):

```sh
sudo -i
export RESTIC_PASSWORD_FILE=/run/secrets/restic_offsite_password
restic -r <lab.backup.offsite.repository> -o sftp.args='-p 23 -i /run/secrets/restic_offsite_ssh_key' snapshots
restic -r <...> restore latest --target / --include /var/lib/paperless --include /var/backup/offsite-staging
# the sqlite dumps land in /var/backup/offsite-staging; copy each over its live db as above
```

Forgejo: restore the newest dump from `~/Sync/Backups/forgejo/` with `forgejo restore` (or unpack it over `/var/lib/forgejo`) as the `git` user.

Then `sudo systemctl start caddy kanidm vaultwarden forgejo woodpecker-server paperless-web` or simply reboot.

## 6. Verify

- `systemctl --failed` is empty, and `journalctl -u sops-install-secrets -b` shows no decrypt errors.
- `dig @nixos-rpi4.lab example.com` answers, and `dig @nixos-rpi4.lab doubleclick.net` returns the blocky block answer.
- From the desktop: `curl -I https://idm.lab https://git.lab https://ci.lab https://vault.lab https://ntfy.lab https://cache.lab/nix-cache-info` all give 2xx/3xx with no TLS warnings (which means the CA key was restored).
- `kanidm login` works, and an `ssh` with a kanidm account works.
- `curl -X POST http://nixos-rpi4.lab:9100/hooks/reset-worker` returns the hook text.
- Trigger the restic backups (`systemctl start restic-backups-offsite`) and the desktop's backup, and check they reach ntfy or metrics.
- Woodpecker: run a manual pipeline. The desktop agent reconnects to `nixos-rpi4.lab:9000`.

## 7. Moving root to a USB SSD

SD cards are the usual failure. Run root from a USB 3 SSD and keep the SD only as a fallback.

1. Use an adapter with working UASP on the Pi 4 (ASMedia ASM1153E/ASM235CM based ones are fine). If `dmesg` shows UAS resets, add `usb-storage.quirks=<vid>:<pid>:u` to `boot.kernelParams` (vid:pid from `lsusb`).
2. Bootloader EEPROM (once, from the running Pi): `sudo rpi-eeprom-config --edit`, then set `BOOT_ORDER=0xf14` (USB first, then SD, then retry). Needs `pkgs.raspberrypi-eeprom`, runnable via `nix shell`.
3. Flash the same image to the SSD (step 1 with the SSD's device), then restore the host key onto it (step 2a).
4. The image mounts root by label `NIXOS_SD`. Two disks with that label make boot pick at random, so relabel the SD's root:

   ```sh
   sudo e2label /dev/mmcblk0p2 NIXOS_SD_SPARE
   ```

   Falling back means relabelling it back (from any Linux box) and pulling the SSD.
5. Boot with only the SSD attached first, check `findmnt /` shows `/dev/sda2`, then put the SD back in.
6. Copy state across with the steps in 5, or `rsync -aHAX` `/var/lib` and `/home` from the old SD before relabelling.
