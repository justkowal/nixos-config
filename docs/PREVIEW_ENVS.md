# Preview environments

Every pull request of a web project on `git.lab` gets a live URL at `http://<name>.dev.lab` (HTTPS via the rpi4).

## Flow

1. The project's `.woodpecker/preview.yaml` (template: `docs/examples/preview.woodpecker.yaml`) runs on the desktop's `preview` agent and drops `{"action","name","flake"}` into `/var/spool/preview-envs/<name>.json`.
2. `preview-envs.path` (root) picks it up, moves it out of the spool, validates it and runs `nixos-container create|update|destroy --flake`.
3. The container gets `10.231.a.b` (host side) / `10.232.a.b` (guest), derived from the name hash. A route file in `/var/lib/preview-envs/routes/` is imported by the desktop's Caddy (`http://*.dev.lab`) and Caddy is reloaded.
4. The rpi4 serves `https://*.dev.lab` and proxies to `nixos-desktop.lab:80`. If the desktop does not answer, the request goes to the `preview-wake` hook, which calls `wake-worker` and returns a self-refreshing "waking" page (503).
5. `pull_request_closed` sends `destroy`; `preview-envs-reap.timer` destroys anything not updated for 7 days.

## Project requirements

- Flake output `nixosConfigurations.container` with `boot.isNspawnContainer = true`, the app on port 80 and `networking.firewall.allowedTCPPorts = [ 80 ]`.
- Flakes are evaluated in pure mode by root, built in the nix sandbox. Repo must live under `git.lab/justkowal/`.

## Validation rules (spool service)

- Regular file under 4 KiB, exactly the keys `action`, `name`, `flake` (all strings).
- `name`: `^[a-z][a-z0-9-]{0,10}$` (11 chars is the nixos-container limit).
- `flake`: `git+https://git.lab/justkowal/<repo>` with optional `?rev=<40 hex>` or `?ref=<ref>` and optional `#attr`.
- Only containers this service created can be updated or destroyed; at most `lab.previewEnvs.maxPreviews` (8) at once; a hash collision on the address is rejected.

## Operating

```
journalctl -u preview-envs -u preview-envs-reap
sudo preview-envs destroy <name>
nixos-container list
```

## Caveats

- Any repo on the forge can target the `type: preview` agent; the flake owner check is what keeps foreign code out.
- The worker idle watchdog does not count preview traffic, so the desktop still powers off after 10 idle minutes; the next visit wakes it.
- Containers have no outbound NAT; add `networking.nat` on the desktop if a preview needs the internet.
