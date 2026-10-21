# MCP gateway (rpi4)

One authenticated streamable-HTTP endpoint for claude.ai: `https://mcp.23012006.xyz/mcp`.
Route: cloudflared `*.23012006.xyz` -> Traefik `127.0.0.1:8088` -> container label `Host(mcp.23012006.xyz)`. No host ports, no tunnel edit.
Source: `hosts/rpi4/mcp-gateway.nix`, `pkgs/mcp-gateway/`.

| Container | Network | Holds | Servers |
| --- | --- | --- | --- |
| `mcp-gateway` | `mcp` + `mcp-internal` | auth, policy, audit, secrets | agh, fleet, mail (stdio children), garmin and everything (remote) |
| `mcp-garmin` | `mcp` (outbound for Garmin) | token volume only | garmin, generated from `garminconnect` |
| `mcp-vault` | `mcp-internal` (no route out) | the vault directory only | everything (notes) |

The garmin and vault containers listen only on the internal network, behind a generated shared token (`/var/lib/mcp-gateway/internal.env`).
Desk tools (`lab_*`) stay desktop-only: they need the Hyprland session and the labd bus.

## The allowlist: `/var/lib/mcp-gateway/policy/tools.json`

```json
{"disabled": [], "enable": [], "classes": {"garmin": []}}
```

- `disabled`: names that are always hidden.
- `enable`: names shown even when their class is not enabled. This is the only way to turn on a destructive or unclassified tool.
- `classes.<server>`: classes shown for a generated or classed server. Defaults: `everything` = read and write, `garmin` = none (empty until you have reviewed the table).
- Takes effect on the next request. A malformed file hides every tool.
- `/var/lib/mcp-gateway/state/catalog.json` lists every tool with its server, class and whether it is currently visible.
- Tools marked sensitive or destructive need `confirm=true` and say so in their description.

## Tools

| Tool | Class |
| --- | --- |
| agh: whoami, list_courses, upcoming_events, course_contents, assignments, course_grades, course_grade_items, notifications, syllabus_subjects, syllabus_subject | read-only |
| fleet_roster, fleet_status, mail_folders, mail_search, mail_read, mail_thread | read-only |
| fleet_wake, mail_draft, mail_move, mail_flag, mail_delete (to Trash only) | state-changing |
| fleet_power, fleet_update, mail_send, mail_reply | security-sensitive (confirm) |
| everything: read_note, read_multiple_notes, read_note_lines, get_note_outline, get_notes_info, get_frontmatter, search_notes, list_directory, list_all_tags, wiki_link, get_vault_stats, list_sync_conflicts | read |
| everything: write_note, patch_note, update_frontmatter, manage_tags | write |
| everything: move_note, move_file, delete_note (to `.trash/`) | destructive, hidden until enabled by name |
| garmin: 260 reads (256 get_*/is_*/download_* plus 4 reviewed search and count tools) | read, hidden until `classes.garmin` includes `read` |
| garmin: 6 menstrual and pregnancy reads | sensitive, hidden until enabled by name |
| garmin: 42 add_/set_/create_/update_/schedule_/upload_*_workout and reviewed calendar and device pushes | write, hidden until `classes.garmin` includes `write` |
| garmin: 28 delete_/remove_/unschedule_, settings and zones, activity uploads and imports, menstrual writes | destructive, hidden until enabled by name |

Garmin: no method is left unclassified after review (see `OVERRIDE` in `garmin_mcp.py`). `upload_hiking_workout` and `upload_walking_workout` are dropped because the library says they always raise.
Never exposed: login, logout, resume_login, connectapi, connectwebproxy, query_garmin_graphql, download, request_reload, now, today.
Library: `garminconnect` 0.3.19, `curl_cffi` 0.16.3, all pinned with hashes in `pkgs/mcp-gateway/garmin/requirements.txt`.

## First-time setup (on the Pi)

```bash
sudo install -d -m 700 /var/lib/mcp-gateway
sudo sh -c 'umask 077; cat > /var/lib/mcp-gateway/secrets.env' <<EOF2
MCP_TOKEN=$(openssl rand -hex 32)
UPEL_TOKEN=<from ~/.config/upel/token on the desktop>
MAIL_ADDRESS=<you>@student.agh.edu.pl
MAIL_PASSWORD=<app password from AGH Webmail>
FLEET_SSH_KEY_B64=<base64 -w0 of the fleet private key, once lab.fleetAgent is enabled>
EOF2
```

The gateway does not start while `secrets.env` is empty, the vault does not start until the Syncthing folder exists, and garmin answers "re-authentication needed" until you log in.

### Garmin login (interactive, MFA)

```bash
sudo podman run -it --rm --user 10001:10001 --network=mcp \
  -v "$(sudo podman inspect mcp-garmin --format '{{range .Mounts}}{{if eq .Destination "/app"}}{{.Source}}{{end}}{{end}}'):/app:ro" \
  -v /var/lib/mcp-garmin/tokens:/garmin/tokens:rw \
  -e GARMINTOKENS=/garmin/tokens "$(sudo podman inspect mcp-garmin --format '{{.ImageName}}')" python /app/garmin_login.py
sudo systemctl restart podman-mcp-garmin
```

The code is mounted read-only from the Nix store, so the one-off container needs the same `/app` mount as the running one (the first `$(...)` finds it). You type the email, password and MFA code yourself. Only the token file is stored. There is no login tool over MCP.
Re-authenticate with the same command when `podman healthcheck run mcp-garmin` reports "re-authentication needed".
Revoke: delete `/var/lib/mcp-garmin/tokens/garmin_tokens.json`, then end the session in Garmin account settings.
Smoke test (enabled read tools, one call each): `sudo podman exec mcp-garmin python /app/garmin_mcp.py smoke`. It also runs daily inside the container.
Upgrade the library: bump the pins in `requirements.txt` (regenerate hashes), switch, re-run `... garmin_mcp.py classes` and the smoke test, review new tools before adding them to `enable`.
Downloads land in `/var/lib/mcp-garmin/output`, uploads are read only from `/var/lib/mcp-garmin/upload`. The token directory is outside `/home` and outside the restic paths. Keep it that way.

## Add in claude.ai

Settings > Connectors > Add custom connector.
- URL: `https://mcp.23012006.xyz/mcp`
- Authentication: No sign-in
- Request headers: `Authorization` = `Bearer <MCP_TOKEN>` (include the word Bearer)

## Vault

The vault is `/home/justkowal/Sync/Notes/Everything` on the Pi, mounted read-write into `mcp-vault` and nothing else.
- Hidden from every tool and not writable: `.obsidian`, `.git`, `.stfolder`, `.stversions`, `.stignore`, `.trash`, `.history`. Symlinks are never followed.
- Overwrites and patches first copy the old version to `.history/`. Syncthing versioning should also be on.
- `delete_note` moves the note to `.trash/<timestamp>__<path>`. Empty it by hand: `sudo podman exec mcp-vault python /app/vault_mcp.py purge-trash 30` (items older than 30 days; omit the number for everything).
- Write scope: set `VAULT_WRITABLE = "ai,inbox"` in `mcp-gateway.nix` for narrow mode, empty for the whole vault, then switch.
- Conflicts: `list_sync_conflicts` and the `conflicts=N` suffix on the vault container's health output. Nothing is resolved automatically.
- Path tests: `pkgs/mcp-gateway/test_vault_mcp.py`.

## Ops

- Logs (audit, JSON lines): `sudo podman logs -f mcp-gateway`. Rotated 5 MB x 3. `alert` marks sensitive calls and repeated auth failures. Garmin and vault calls log tool, class and the path or date only.
- Restart: `sudo systemctl restart podman-mcp-gateway podman-mcp-garmin podman-mcp-vault`
- Update: edit, `git add`, `nh os switch` on the Pi.
- Disable a tool: add it to `disabled` in `tools.json`.
- Rotate a credential: change it in `secrets.env` and restart. For `MCP_TOKEN` also re-add the connector. For the internal token delete `internal.env` and restart all three.
- Remove a server: drop it from `children` and its container in `mcp-gateway.nix`, switch.
- Remove everything: delete the connector in claude.ai, drop the import of `mcp-gateway.nix`, switch.
- Mail send limit: 20/hour (`MAIL_SEND_LIMIT`). From is always the student address.

## Vault sync and backup

State on 2026-10-20:
- Syncthing folder `notes-everything` ("Everything") pairs the laptop and the Pi, send and receive on both, staggered versioning (90 days) on both. Global discovery, relays and NAT traversal are off on both; devices connect by explicit tailnet address. The GUI is on loopback only.
- Add a device (for example nixos-desktop): on that device and on the Pi, add the other's device ID with address `tcp://<tailnet ip>:22000`, then share the folder, path `~/Sync/Notes/Everything`. IDs: `syncthing cli show system` or the GUI.
- The Pi is the intended source of truth, but Syncthing has no hard primary: both sides send and receive. Edit on one side at a time when you can.
- Conflicts show as `*.sync-conflict-*` files. `list_sync_conflicts` lists them. Open both versions, keep one, delete the other.
- Do not point the desktop MCP config at the Pi copy until you have used the sync both ways for a while. Retire the old copy only after about a week of verified sync.

Backup (`hosts/rpi4/notes-backup.nix`, `hosts/rpi4/scripts/notes-backup.sh`):
- 03:40 nightly: tar, zstd, `age` encrypt to a public recipient, commit to the private repo `github.com/justkowal/notes-backup`. Keeps 14 dailies and 8 Sunday snapshots in the working tree. Git history keeps every snapshot (a few tens of KB each).
- The Pi holds only the public recipient and a deploy key for that one repo (`~/.local/state/notes-backup/deploy_key` on the Pi). It cannot read old snapshots.
- The age private key is on the laptop at `~/.local/share/notes-backup/age.key`. Copy it into your password manager now. Without it the backups are unreadable. It is not in the vault, the repo or the Pi.
- The timer starts with the next switch of the Pi. The first snapshot was already pushed by hand with the same script.
- Failure notifications use `backup-failed-ntfy@`.

Restore a note or the vault (tested 2026-10-20, 37 files, checksums identical):

```bash
gh repo clone justkowal/notes-backup /tmp/nb && cd /tmp/nb
age -d -i ~/.local/share/notes-backup/age.key snap-YYYY-MM-DD.tar.zst.age | zstd -d | tar -C /tmp/restore -xf -
```

Restore a single note, in order of effort: `.trash/` in the vault (deleted via MCP), `.history/` (overwritten or patched via MCP), Syncthing versions in `.stversions/` (90 days), then the backup.
If the Pi's SD card dies: the laptop still has the full vault and all snapshots are on GitHub. Reflash, switch, re-pair Syncthing (minutes), restore if needed. The Pi runs from an SD card only: a USB SSD for the vault is recommended.

## Maps and transit

The gateway also fronts the `osm` and `routing` servers (local Nominatim and OpenTripPlanner, feed registry, desktop-built graphs). Everything about them is in `MAPS.md`: architecture, measured numbers, the restricted desktop keys, the build and swap flow, and the runbook. Their audit lines carry only tool, class and status. The feed admin tools (`feed_add`, `feed_remove`, `feed_set_enabled`, `graph_rebuild_request`) are hidden until enabled by name in `tools.json`, and use their own `confirmed` flag.

The Garmin smoke test now starts at container boot (inner servers start their child eagerly) and repeats daily.
