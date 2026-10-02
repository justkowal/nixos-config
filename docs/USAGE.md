# Scale-to-Zero Homelab — User Guide & Operations Manual

This guide explains how to connect to, interact with, and leverage the services running in the scale-to-zero homelab from your **Laptop**, **Desktop**, or **Mobile devices**.

---

## 1. Network Connectivity & Access

All homelab services are published on the private **Tailscale** mesh network using `.lab` domains and reverse-proxied with HTTPS via Caddy on the Raspberry Pi 4.

### 1.1 Setting Up & Connecting via Tailscale

All internal homelab services (`*.lab`) live within your encrypted Tailscale mesh network. Because Tailscale uses WireGuard over UDP with NAT-traversal (DERP relays), it seamlessly connects your devices even when your homelab is behind CGNAT or strict hotel/mobile Wi-Fi.

#### On Your Laptop (NixOS / Linux)
The laptop configuration automatically includes `services.tailscale.enable = true;`.

1. **Authenticate and connect**:
   ```bash
   sudo tailscale up
   ```
   Follow the login URL in your browser to authorize your laptop to the Tailnet.

2. **Verify connection**:
   ```bash
   # Check Tailnet status and list peer nodes
   tailscale status

   # Ping the orchestrator over WireGuard
   tailscale ping nixos-rpi4
   ```

3. **Verify MagicDNS resolution**:
   ```bash
   ping -c 2 nixos-rpi4.lab
   ```

#### On Mobile Devices (iOS / Android) & macOS / Windows
1. Install the official **Tailscale** application from the App Store or Google Play.
2. Sign in with the same account (GitHub/Google).
3. Connect the VPN switch.
4. You can now immediately browse to `https://idm.lab`, `https://git.lab`, `https://ci.lab`, etc., directly from your phone browser without exposing anything to the public internet!

### 1.2 Service Directory

| Service | Internal URL (Tailscale) | Public URL | Description |
| :--- | :--- | :--- | :--- |
| **Kanidm (Identity)** | `https://idm.lab` | — | Single Sign-On, credentials, MFA & SSH keys |
| **Forgejo (Git & OCI)**| `https://git.lab` | — | Code repositories and OCI container registry |
| **Woodpecker CI** | `https://ci.lab` | — | Continuous integration dashboard & pipelines |
| **Flamenco Manager** | `http://render.lab` | — | Blender render queue and farm coordination |
| **Portfolio Website** | `https://portfolio.lab` | `https://portfolio.justkowal.dev` | Personal website (routed via Cloudflare tunnel) |
| **Webhook Receiver** | `http://nixos-rpi4.lab:9100` | — | Remote WoL trigger and boot target switcher |
| **Desktop Sandbox** | `ssh sandbox@nixos-desktop.lab` | — | Ephemeral isolated Docker container shell |

> [!TIP]
> **Zero Certificate Warnings**: The Homelab Internal Root CA is declaratively distributed to the system trust store on all nodes (Laptop, Desktop, VM, Pi) via `security.pki.certificates` in `modules/security.nix`. All `*.lab` HTTPS services are trusted out of the box with zero browser or CLI warnings.

> [!NOTE]
> **Zero Password SSH**: Your primary SSH public key (`~/.ssh/id_ed25519.pub`) is declaratively provisioned to `authorizedKeys` on all nodes (RPi4, Desktop, Laptop) via `modules/security.nix`. All SSH commands (`justkowal@...` or `sandbox@...`) connect seamlessly without prompting for passwords.

---

## 2. Unified Identity & Single Sign-On (Kanidm)

Kanidm serves as the single source of truth for user authentication across web services and local system accounts.

### 2.1 Managing Your Account & MFA
1. Open `https://idm.lab` in your web browser.
2. Sign in with your username (`justkowal`) and password.
3. In the self-service portal, you can:
   - Change your password.
   - Register **FIDO2 / WebAuthn** passkeys (YubiKey, fingerprint, or platform authenticator).
   - Upload and manage your personal **SSH public keys**.

### 2.2 System Authentication on the Laptop (Online & Offline)
Your laptop is enrolled as a Kanidm client via `kanidm-unixd`:
- **PAM Authentication**: System login, `sudo`, `su`, and `hyprlock` screen locking automatically authenticate against Kanidm.
- **Offline Travel Mode**: When disconnected from the network or traveling, `kanidm-unixd` transparently validates credentials against the local cache at `/var/cache/kanidm-unixd/cache.db`.
- **Local Fallback**: Local system accounts (`root`, wheel group) are prioritized first via NSS order `400` so emergency access is never compromised.

---

## 3. Git Repositories & Container Registry (Forgejo)

Forgejo provides lightweight, fast Git hosting with an integrated OCI container registry.

### 3.1 Signing In via OIDC
1. Navigate to `https://git.lab`.
2. Click **Sign In**, then choose **Sign in with Kanidm**.
3. Authorize via Kanidm SSO. Your profile and permissions are synced automatically.

### 3.2 Cloning and Pushing Code
You can clone and push repositories over SSH or HTTPS:

```bash
# Clone a repository over SSH
git clone git@git.lab:justkowal/homelab-infra.git

# Or over HTTPS using your Kanidm credentials / Git token
git clone https://git.lab/justkowal/homelab-infra.git
```

### 3.3 Using the Built-In Container Registry
Forgejo hosts an OCI-compliant container registry on the same domain:

```bash
# Log into the registry using Podman or Docker
podman login git.lab
# Username: justkowal
# Password: <Your Forgejo Access Token or Kanidm password>

# Build and tag a container image
podman build -t git.lab/justkowal/my-app:latest .

# Push to the homelab registry
podman push git.lab/justkowal/my-app:latest
```

---

## 4. Dynamic Public Subdomains via Cloudflare Tunnel (`*.23012006.xyz`)

You can launch any container on the Raspberry Pi 4 and have it instantly self-register a public subdomain on `*.23012006.xyz` without modifying any NixOS configuration files, restarting services, or editing Cloudflare DNS records.

### 4.1 How It Works (100% CGNAT-Proof)

```
[Public Internet]
       │
       ▼ (HTTPS :443)
[Cloudflare Edge]
       │
       ▼ (Persistent Outbound QUIC/HTTP2 Tunnel)
[cloudflared on RPi4]
       │ (Wildcard *.23012006.xyz)
       ▼ (HTTP 127.0.0.1:8088)
[Traefik Dynamic Router]
       │ (unix:///run/podman/podman.sock)
       ▼ (Auto-discovered via container labels)
[Your Container on RPi4]
```

1. **CGNAT Traversal**: `cloudflared` initiates outbound connections to Cloudflare. Inbound public requests travel down this tunnel, requiring no open ports on your home router.
2. **Wildcard Routing**: All traffic for `*.23012006.xyz` and `23012006.xyz` is forwarded to Traefik on `127.0.0.1:8088`.
3. **Dynamic Podman Discovery**: Traefik continuously watches `/run/podman/podman.sock`. When a container starts with `traefik.enable=true`, Traefik automatically wires the requested subdomain to the container's internal port.
4. **Security Boundary**: Traefik runs with `exposedByDefault = false`. Private or internal containers without explicit Traefik labels are never exposed to the public internet.

---

### 4.2 Launching a Self-Registering Container

To expose a container under `something.23012006.xyz`, simply add Traefik router labels when starting the container.

#### Method A: Using `podman run` (CLI)

```bash
podman run -d \
  --name my-api \
  --network podman \
  --restart always \
  --label "traefik.enable=true" \
  --label "traefik.http.routers.myapi.rule=Host(\`something.23012006.xyz\`)" \
  --label "traefik.http.services.myapi.loadbalancer.server.port=8080" \
  docker.io/library/nginx:alpine
```

As soon as the container is running, test the route:
```bash
curl -i https://something.23012006.xyz
```
Cloudflare automatically provisions public TLS certificates at the edge and securely streams traffic to your local container.

#### Method B: Using `compose.yaml` (Podman / Docker Compose)

```yaml
services:
  web:
    image: ghcr.io/my-org/web-service:latest
    restart: unless-stopped
    networks:
      - podman
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.web.rule=Host(`demo.23012006.xyz`)"
      - "traefik.http.services.web.loadbalancer.server.port=3000"

networks:
  podman:
    external: true
```

#### Method C: Destroying / Updating a Route
- When you stop or remove the container (`podman rm -f my-api`), Traefik detects the event in real time and tears down the route.
- Cloudflare will return `HTTP 404` until another container claims that subdomain.

---

## 5. Continuous Integration & Ephemeral Builds (Woodpecker)

Woodpecker runs lightweight server orchestration on the Pi, but offloads all heavy build and test workloads to the Desktop.

### 5.1 Creating a Pipeline
Add a `.woodpecker.yaml` file to your repository root:

```yaml
# .woodpecker.yaml
pipeline:
  test:
    image: nixos/nix:latest
    commands:
      - nix --version
      - nix flake check

  build:
    image: docker:24-cli
    commands:
      - echo "Building container on Desktop SSD..."
```

### 5.2 Automatic Scale-to-Zero Execution
When you push code to Forgejo:
1. Forgejo notifies Woodpecker via webhook.
2. If the Desktop is powered off, a webhook on Forgejo or Woodpecker triggers the Pi's scale-to-zero wake receiver:
   ```bash
   POST http://nixos-rpi4.lab:9100/hooks/wake-worker
   ```
3. The Pi sets `boot-state.cfg` to `server` and broadcasts a Wake-on-LAN magic packet.
4. The Desktop boots into the **Worker Specialisation** (headless, no display manager, high CPU limits).
5. The Woodpecker agent on the Desktop picks up the pipeline and executes container steps on the fast btrfs SSD (`/var/lib/docker`).
6. Once all builds complete and no renders or sessions are running, the Desktop's `worker-watchdog` automatically powers the machine down after 10 minutes of inactivity.

---

## 6. 3D Render Farm (Blender & Flamenco)

The homelab includes an automated render farm powered by Blender Flamenco. The Manager runs on the Pi 4, while the Worker runs on the Desktop with full GPU acceleration.

### 6.1 Setting Up Blender on Your Laptop

1. Open Blender on your Laptop.
2. In **Edit → Preferences → Add-ons**, enable the **Flamenco 3** add-on (bundled with Blender or downloaded from flamenco.blender.org).
3. In the Flamenco add-on settings:
   - **Manager URL**: `http://render.lab` (or `http://100.x.y.z:8080`)
   - **Storage Path**: `/home/justkowal/Sync/Render`

### 6.2 File Synchronization (Syncthing)
Syncthing runs on the Laptop, Desktop, and Pi 4, keeping `/home/justkowal/Sync/Render` synchronized across all machines:
- Place your `.blend` files and textures inside `/home/justkowal/Sync/Render/projects/`.
- Syncthing propagates the files to the Pi and Desktop in the background.

### 6.3 Submitting a Render Job
1. In Blender's Properties panel, open the **Flamenco** tab.
2. Configure your render settings (frame range, output format, render engine).
3. Click **Submit to Flamenco**.
4. Monitor job progress in your browser at `http://render.lab`.
5. The Desktop will automatically process chunks. When complete, rendered frames synchronize back to your Laptop via Syncthing.

---

## 7. Remote Ephemeral Docker Sandbox

Need to test untrusted code, run scratch builds, or experiment in a clean environment from your laptop? The Desktop provides a disposable SSH Docker sandbox.

### 7.1 Connecting from Your Laptop (Automatic Wake & Live Status)

You don't need to check whether the Desktop is awake before connecting. Run standard SSH:

```bash
ssh sandbox@nixos-desktop.lab
```

#### What Happens When the Desktop is Asleep:
The laptop's SSH client automatically executes the Pi's `wake-and-proxy` bridge via Home Manager SSH configuration. You receive live terminal updates streamed to your console while you wait:

```text
🖥️  Desktop is powered off (scale-to-zero).
⚡ Sending Wake-on-LAN and setting boot target to 'server'...
⏳ Waiting for Desktop to boot and start SSH...
   Booting Desktop... (14s elapsed)
✨ Desktop is online! Handing off SSH session...
```

As soon as the Desktop's SSH daemon responds, the connection completes automatically and you are dropped directly into your ephemeral container.

#### Connecting from Any Device (Mobile / Tablet / New Host):
If connecting from a machine without pre-configured SSH settings, connect directly to the Pi's bridge endpoint:

```bash
ssh sandbox@nixos-rpi4.lab
```
The Pi will display the same live boot progress and forward your interactive terminal session straight into the Desktop's sandbox container.

### 7.2 How the Sandbox Works
- **Instant Launch**: Instead of giving you a host shell, the SSH connection triggers a hardened wrapper script (`/run/current-system/sw/bin/...`).
- **Clean Ephemeral Container**: You are immediately dropped into an `alpine:edge` container (with `git`, `curl`, `bash`, `build-base`, and `python3`).
- **Security Boundaries**:
  - `--cap-drop ALL`: Linux capabilities are completely dropped.
  - `--security-opt no-new-privileges`: Blocks setuid privilege escalation.
  - Isolated network bridge: No direct access to host network namespaces.
  - No access to `/var/run/docker.sock` or host filesystems.
  - SSH port and stream forwarding are strictly disabled.
- **Auto-Cleanup**: When you exit the shell (`exit` or `Ctrl+D`), the container is automatically destroyed with `--rm`.

---

## 8. Manual Scale-to-Zero Controls

You can manually inspect, wake, or reset the Desktop's state at any time from your laptop terminal.

### 8.1 Waking Desktop in Worker Mode (Headless CI/Render)
Send a POST request to the Pi's webhook receiver:

```bash
curl -X POST http://nixos-rpi4.lab:9100/hooks/wake-worker
```
- Sets `my_boot_target="server"` in `/var/www/boot-state/boot-state.cfg`.
- Sends a Wake-on-LAN magic packet to the Desktop's network interface.
- Desktop boots headless into the Worker specialisation.

### 8.2 Resetting Desktop to Normal Interactive Mode (Hyprland)
When you want the Desktop ready for gaming, development, or local use:

```bash
curl -X POST http://nixos-rpi4.lab:9100/hooks/reset-worker
```
- Sets `my_boot_target="desktop"` in `boot-state.cfg`.
- The next time the Desktop boots (via power button or WoL), it boots directly into your default Hyprland desktop environment.

### 8.3 Manual Boot Override via Keyboard
If you are sitting at the physical Desktop and want to override the network boot target:
- Simply hold `SHIFT` as the PC powers on.
- GRUB will display the interactive boot menu, allowing you to choose between default Desktop mode or Worker specialisation regardless of the network state.

### 8.4 Checking Watchdog Status
To observe the scale-to-zero inactivity timer on the Desktop:

```bash
# On the Desktop (or via SSH in desktop mode):
systemctl status worker-watchdog.service
journalctl -u worker-watchdog -f
```
The watchdog will report active Docker containers, Blender render processes, and sandbox sessions every 30 seconds.

---

## 9. Operator Secrets Management (SOPS Cheat Sheet)

All homelab cluster secrets are managed declaratively via `sops-nix`. Secrets are encrypted with asymmetric authenticated cryptography (AES-256-GCM + age) in `hosts/rpi4/secrets/secrets.yaml`. **Encrypted secrets files are completely safe to commit and push to Git.**

### 9.1 Interactive Editing (Replacing Placeholders)
Whenever you receive new API credentials or tokens:

```bash
sops hosts/rpi4/secrets/secrets.yaml
```

- SOPS uses your local key at `~/.config/sops/age/keys.txt` to decrypt the file into your editor.
- Replace any placeholder values:
  ```yaml
  cloudflare_tunnel_credentials: "placeholder"
  woodpecker_agent_secret: "placeholder"
  woodpecker_gitea_client: "placeholder"
  woodpecker_gitea_secret: "placeholder"
  homelab_ca_key: "placeholder"
  tailscale_auth_key: "tskey-auth-..."
  ```
- Save and exit. The file is automatically re-encrypted in-place.

### 9.2 Setting a Secret via CLI
To update a single secret without opening an interactive editor:

```bash
sops set hosts/rpi4/secrets/secrets.yaml '["woodpecker_agent_secret"]' '"your-generated-token"'
```

### 9.3 Inspecting Decrypted Secrets
To inspect the plaintext values in your terminal:

```bash
sops -d hosts/rpi4/secrets/secrets.yaml
```

### 9.4 Adding a New Host Key (Re-keying)
When deploying a new node or the RPi4 for the first time:

1. Obtain the new host's age public key from its SSH host key:
   ```bash
   nix-shell -p ssh-to-age --run "ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub"
   ```
2. Add the age recipient key to `.sops.yaml` in the repo root.
3. Re-encrypt the existing secrets with the updated recipient list:
   ```bash
   sops updatekeys hosts/rpi4/secrets/secrets.yaml
   ```

