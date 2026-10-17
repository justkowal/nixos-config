# Android phone and tablet setup

Step by step, for a phone and a tablet that have never been set up for this lab. Written from what the repo actually does, so each part says what is broken or missing before it tells you what to tap. Menu names are for Android 14 and 15 and Nothing OS; other versions word things slightly differently.

Phone: Nothing Phone (2a), already known to the tailnet but offline for about two weeks. Tablet: not in the tailnet yet.

## What works out of the box and what does not

| Feature | Works with no setup? | What blocks it | Part |
| :--- | :--- | :--- | :--- |
| Reaching the lab from outside the house | No | Tailscale is not signed in on the tablet and is off on the phone | 1 |
| Names like `git.lab`, `ci.lab`, `idm.lab` | No | They only resolve through a hosts file that exists on the NixOS machines, not on Android | 2 |
| HTTPS to those names without warnings | No | The lab certificates come from your own root CA, which Android does not trust | 3 |
| Alerts and focus notices on the phone | No | The ntfy app is not installed or subscribed, and it may not accept your own CA | 4 |
| Lab phone app (scenes, device roster) | No | Off by default, and the ACL had no rule for its port until this change | 5 |
| Streaming the desktop with Moonlight, tablet as a second screen | No | Pairing is manual; waking the desktop by itself is not enabled | 6 |
| KDE Connect (clipboard, notifications, files) | No | Pairing is manual and must be done by address over Tailscale | 7 |
| Syncthing folders | No | Device IDs have to be exchanged by hand | 8 |
| Single sign-on (Kanidm) | No | Needs parts 2 and 3 first, then a credential link | 9 |
| SSH from the phone | No | Needs Termux and a key | 10 |

Before starting, confirm on the computers:

1. The laptop and the desktop are switched to the latest config (`nh os switch`).
2. The rpi4 hub is deployed with the current repo (it provides `.lab` DNS through Blocky, ntfy and the focus hooks). It was redeployed on 2026-10-17 and `dig @100.113.193.14 git.lab +short` answers `100.113.193.14`; the runbook is at the end of `docs/DEPLOYMENT.md`. Check from a computer: `curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://nixos-rpi4.lab:9100/hooks/focus-status` should not print `404`.
3. The Tailscale policy in `tailscale/policy.hujson` is either applied or not applied, both work (see the warning in part 1).

---

## Part 1. Tailscale on both devices

Everything else rides on this.

**On the phone**

1. Open the Tailscale app. If it is gone, install it from Google Play.
2. Sign in with the same account the computers use (`justkowal@`). The phone has been offline for about two weeks, so you may be asked to log in again. Approve the sign-in on the other device if asked.
3. Switch the VPN toggle on and accept the Android VPN prompt.
4. App settings: turn on **Use Tailscale DNS settings**. Parts 2 and 4 need it.
5. Stop Android killing it: Settings, Apps, Tailscale, Battery, set **Unrestricted** (Nothing OS: also allow autostart and keep it locked in the recent apps list).
6. Optional but useful: Settings, Network and internet, VPN, gear icon next to Tailscale, turn on **Always-on VPN**. Leave **Block connections without VPN** off, otherwise the phone loses the internet whenever Tailscale is down.

**On the tablet** repeat the same six steps. It will join as a new device. Give it a clear name in the Tailscale admin console (Machines, three dots, Edit machine name), for example `tablet`.

**Check:** on the laptop run `tailscale status`. Both devices should be listed and `online`. From each Android device open the Tailscale app and tap `nixos-rpi4`, then Ping.

**Warning about tagging.** `tailscale/policy.hujson` says to give the laptop and phone `tag:roaming`. Tailscale does not offer Taildrop (file sharing) for tagged devices, and the room transfer between the laptop and the desktop uses Taildrop. Until the policy is applied your untagged devices reach everything through the bootstrap grant. Recommendation: do not tag the devices you want to send rooms between, or accept that room transfer and Taildrop to the phone stop working.

---

## Part 2. Make `*.lab` names resolve on Android

On the NixOS machines `*.lab` names come from `modules/lab-hosts.nix`, a static hosts file. Android has no such file. The rpi4 runs Blocky, which answers `.lab` names from `lab.dnsMapping`, so the fix is to point Tailscale at it for that one domain.

1. Open the Tailscale admin console in a browser: DNS.
2. Make sure **MagicDNS** is on.
3. Under **Nameservers**, choose **Add nameserver**, then **Custom**.
4. Enter the rpi4 tailnet address `100.113.193.14` (check it in the Machines list, it is the address of `nixos-rpi4`).
5. Turn on **Restrict to domain** and enter `lab`. This sends only `*.lab` lookups to the Pi and leaves the rest of your DNS alone.
6. Save.
7. Toggle Tailscale off and on again on each Android device so it picks the setting up.

**Check:** in the phone browser open `http://nixos-rpi4.lab` or `https://lab`. If it says the site cannot be found, wait a minute, toggle Tailscale again, and confirm step 4 and 5. A certificate warning at this point is expected and is fixed in part 3. From a computer you can test the Pi directly: `dig @100.113.193.14 git.lab +short` should print `100.113.193.14`.

---

## Part 3. Trust the lab root CA

Caddy on the Pi serves every `*.lab` name with `tls internal`, signed by your own root CA (`modules/certs/homelab-ca.crt`). The NixOS machines trust it through `modules/security.nix`. Android does not.

1. Send the certificate to the Android device. Easiest: on the laptop, in the repo folder, run
   `tailscale file cp modules/certs/homelab-ca.crt nothing-phone-2a:`
   (use the device name shown by `tailscale file cp --targets`). This only works for untagged devices, see part 1. Otherwise use USB, or a cloud drive you trust.
2. On the Android device open the Taildrop notification (or the file list in the Tailscale app) and save `homelab-ca.crt` to Downloads.
3. Make sure a screen lock is set. Android refuses to install certificates without one.
4. Settings, Security and privacy, More security and privacy, Encryption and credentials, **Install a certificate**, **CA certificate**. Read the warning, choose **Install anyway**, pick `homelab-ca.crt`.
5. Android will now show a permanent notice that the network may be monitored. That is normal for any user-installed CA.

**Firefox for Android** ignores user CAs by default. Open Firefox, Settings, About Firefox, tap the Firefox logo five times to reveal secret settings, then Settings, **Secret Settings**, turn on **Use third party CA certificates**, and restart it. Chrome needs nothing extra.

**Be aware:** many Android apps ignore user-installed CAs completely. Browsers work. Apps that talk to `*.lab` over HTTPS themselves may not. Part 4 deals with the one that matters (ntfy).

**Check:** in Chrome open `https://git.lab` and `https://lab`. There must be no warning.

---

## Part 4. Alerts and focus notices on the phone (ntfy)

The rpi4 sends alerts (disk, services, temperature and so on, through `alert-ntfy.py`) and focus on/off notices to its ntfy server. The desktop already shows them through its own listener. The phone needs the app.

1. Install **ntfy** from Google Play or F-Droid.
2. Open it, tap **+** to subscribe, and use the server and topic:
   - First try your own server: toggle **Use another server**, enter `https://ntfy.lab`, topic `alerts`.
   - If it shows a certificate error, the app is not trusting your CA (Android apps often do not). Use the public name instead: `https://ntfy.23012006.xyz` (served through your Cloudflare tunnel). Anyone who guesses the topic name could read it there, so treat that as a reason to rename the topic or add authentication in ntfy before relying on it.
3. Subscribe to a second topic, `focus`, the same way.
4. Let it run in the background: Settings, Apps, ntfy, Battery, **Unrestricted**. In ntfy, Settings, enable **Keep alerts for important notifications** if offered.
5. Notification channels: Android settings for ntfy, make the `alerts` channel **High priority** so it makes sound.

**Check:** on the laptop run `curl -d "test from the laptop" https://ntfy.lab/alerts`. The phone should buzz within a few seconds.

---

## Part 5. The Lab phone app

A small web app that shows your devices, the last things that happened, and lets you start a scene (Welcome back, Focus, Leave) on a computer. It is switched off by default and only ever listens on that computer's Tailscale address, protected by a token.

On the computer you want to control (for example the desktop):

1. In its Home Manager config set `lab.phone.enable = true;` (for example in `home/default.nix`, next to `lab.rooms.enable`).
2. Apply the Tailscale policy change that opens port 8765 (`tailscale/policy.hujson`, merge to main so CI applies it) if you use the policy. If you do not, the bootstrap grant already allows it.
3. Switch the computer (`nh os switch`). The first start creates a private token file at `~/.config/lab/phone-token`.
4. Run `lab phone`. It prints a URL and the token. Or press `SUPER + SPACE`, type `phone` and choose **Phone app: copy the token**, which copies the token and shows a notification with the URL.

On the Android device:

1. Make sure Tailscale is on.
2. Open the URL in Chrome. It is plain `http` on purpose: the connection is already encrypted by Tailscale, and the page cannot use a certificate for a bare tailnet address.
3. Paste the token once. It is stored only on the phone.
4. Chrome menu, **Add to Home screen**, then **Install** if Chrome offers it. You get an icon that opens full screen.

Scenes ask for a second tap within three seconds, so a stray touch cannot lock your desktop.

**Check:** the Devices list shows your computers with a filled dot when online. Tapping a scene twice makes the island on the computer announce it.

---

## Part 6. Moonlight: stream the desktop, and use the tablet as a second screen

Sunshine is already enabled on the desktop. The setup that is missing is pairing, and for waking a sleeping desktop, two options that are off.

**Pair once (phone and tablet each)**

1. Make sure the desktop is on and awake, and that the Android device is on Tailscale.
2. On the desktop open the Sunshine web UI at `https://nixos-desktop.lab:47990` (the browser will warn about Sunshine's own certificate, accept it). The first time it asks you to create a username and password for Sunshine. Do that.
3. On the Android device install **Moonlight** from Google Play.
4. In Moonlight tap **+** (add host manually) and enter the desktop's tailnet address `100.109.222.110` (or `nixos-desktop.lab` if part 2 works). It shows a PIN.
5. In the Sunshine web UI open **PIN**, enter the PIN and a device name, and submit.
6. Back in Moonlight the desktop shows as paired. Tap it and choose **Desktop**.

**Tablet as a second display**

1. On the desktop press `SUPER + SHIFT + T`, or open the palette and choose **Tablet display: toggle**. This creates a virtual 1920x1200 screen in Hyprland.
2. Connect from the tablet with Moonlight and choose **Desktop**. Sunshine streams the displays; if it streams the wrong one, set the output in the Sunshine web UI, Configuration, Audio/Video, **Output Name**.
3. Quit streams from Moonlight with the Quit option rather than just closing it, otherwise the desktop thinks a stream is still active.

**Waking the desktop from the phone or tablet (optional, off today)**

1. Buy an HDMI dummy plug (about 30 PLN) and plug it into the desktop, or set an EDID override.
2. Enable `lab.streamHost.enable = true;` in `hosts/desktop/configuration.nix` and `lab.streamWake.enable = true;` in `hosts/rpi4/configuration.nix`, then deploy both. Details are in `docs/SETUP_GUIDE.md` section 8.
3. Then open `https://play.lab` on the Android device to wake the desktop and wait for Sunshine, then connect with Moonlight.
4. The desktop's BIOS needs Wake-on-LAN enabled (see `docs/DEPLOYMENT.md` section 3.2).

**Check:** pick **Desktop** in Moonlight and move the mouse. The picture is smooth and the tablet shows the extra screen.

---

## Part 7. KDE Connect

The computers already run KDE Connect. On Android it pairs by address over Tailscale because discovery by broadcast does not cross the VPN.

1. Install **KDE Connect** from Google Play or F-Droid on each Android device.
2. Open it, menu, **Add devices by IP**, enter the laptop's tailnet address, then the desktop's. (Addresses: `tailscale status` on any computer.)
3. Accept the pairing request on the computer (a KDE Connect notification) and on the phone.
4. Grant the plugins you want: clipboard, notifications, file transfer, media controls. Android will ask for notification access and storage permissions.
5. Battery: Settings, Apps, KDE Connect, Battery, **Unrestricted**.

**Check:** copy text on the phone and paste it on the laptop. Send a file from the phone's share sheet to the laptop.

---

## Part 8. Syncthing

Syncthing is enabled on the computers and the Pi with their web interfaces on `127.0.0.1:8384`. Devices and folders are not declared in the repo, so you add them by hand.

1. Install **Syncthing-Fork** from F-Droid or the Play Store Syncthing app on each Android device. Allow it to run in the background (battery **Unrestricted**) and grant storage access.
2. On the phone open Syncthing, menu, **Show ID** to see its device ID.
3. On the desktop open `http://127.0.0.1:8384`, **Add Remote Device**, paste the phone's ID, give it a name, tick the folders to share. Save.
4. On the phone accept the incoming device request, then accept each shared folder and choose where to store it.
5. Repeat for the laptop, or share the same folders from the desktop only and let it relay.
6. Phone settings worth turning on: sync only on Wi-Fi or while charging, so it does not drain the battery.

**Check:** add a file to a shared folder on the desktop and see it appear on the phone.

---

## Part 9. Single sign-on (Kanidm) from Android

Kanidm at `https://idm.lab` signs you in to Forgejo, Woodpecker and the other services. It needs parts 2 and 3 first.

1. Open `https://idm.lab` in Chrome on the Android device and sign in with your Kanidm account.
2. To add a passkey for the phone, create a credential update link on a computer: `kanidm person credential create-reset-token <your-user>` (you need to be logged in to the `kanidm` client). Open the link on the phone and follow the steps to register a passkey or a TOTP code.
3. Sign in to `https://git.lab` and `https://ci.lab` with the single sign-on button to confirm.

---

## Part 10. Optional: SSH from the phone

1. Install **Termux** from F-Droid.
2. In Termux run `pkg install openssh` and `ssh-keygen -t ed25519`.
3. Show the public key with `cat ~/.ssh/id_ed25519.pub` and add it to your Kanidm account's SSH keys or to the machine's authorized keys.
4. Connect with `ssh justkowal@nixos-desktop.lab` (the Pi wakes it through the proxy command on your computers, from the phone use `ssh sandbox@nixos-rpi4.lab` as described in `docs/USAGE.md` section 7).

---

## Final check, from the phone

1. Tailscale is connected and lists the laptop, desktop and rpi4 as online.
2. `https://lab` opens with no certificate warning.
3. `curl -d "hello" https://ntfy.lab/alerts` on a computer makes the phone buzz.
4. The Lab phone app shows the devices and a scene runs when tapped twice.
5. Moonlight shows the desktop and starts a stream.
6. KDE Connect clipboard sync works both ways.
7. A Syncthing test file arrives.

If something fails, the Health page of the help window (`SUPER + /` on a computer) and `lab doctor` show the computer side, and the Tailscale admin console shows which device is offline.
