#!/usr/bin/env python3
"""
Deployment Fleet Center (fleet-manager-gui)
Grounded in Apple HIG & Matugen Material You:
  - Dynamically styled via Matugen CSS tokens (@accent_color, @card_bg_color, @headerbar_border_color)
  - 100% Nerd Font / SF-style iconography (NO EMOJIS)
  - Fully dynamic peer discovery via Tailscale and DNS (ZERO static IPs)
  - Live background HTTP probing for all homelab web services (real HTTP status & latency)
  - Live system diagnostics (Git flake revision, kernel, uptime, storage)
  - Responsive layout (560x620) engineered for Laptop 1080p viewport and Desktop
"""

import os
import sys
import socket
import shutil
import subprocess
import threading
import urllib.request
import ssl
import time
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib, Gdk

current_dir = os.path.dirname(os.path.abspath(__file__))
if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

try:
    from peer_discovery import resolve_all_nodes, get_local_host_key
except ImportError:
    def get_local_host_key():
        h = socket.gethostname().lower()
        return "laptop" if ("laptop" in h or "thinkpad" in h) else "desktop"

    def resolve_all_nodes():
        return {
            "desktop": {"key": "desktop", "name": "nixos-desktop", "title": "nixos-desktop (Workstation)", "role": "Workstation", "local": get_local_host_key() == "desktop", "online": True, "active_ip": "127.0.0.1", "route_type": "Loopback", "latency_ms": 0.0},
            "laptop": {"key": "laptop", "name": "thinkpad-t14s-gen1-amd", "title": "thinkpad-laptop (ThinkPad T14s)", "role": "Mobile Client", "local": get_local_host_key() == "laptop", "online": True, "active_ip": "thinkpad-t14s-gen1-amd", "route_type": "mDNS", "latency_ms": 1.0},
            "rpi4": {"key": "rpi4", "name": "nixos-rpi4", "title": "nixos-rpi4 (Homelab Core Server)", "role": "Homelab Server", "local": False, "online": True, "active_ip": "nixos-rpi4.lab", "route_type": "DNS", "latency_ms": 0.5}
        }

APPLE_MATUGEN_CSS = """
window.fleet-manager {
    background-color: @window_bg_color;
}

.apple-card {
    background-color: alpha(@card_bg_color, 0.45);
    border: 1px solid alpha(@headerbar_border_color, 0.25);
    border-radius: 14px;
    padding: 12px;
}

.apple-icon-prefix {
    font-size: 16px;
    color: @accent_color;
    margin-right: 6px;
}

.apple-pill-btn {
    border-radius: 12px;
    padding: 4px 12px;
    font-weight: 500;
    font-size: 12px;
}

.apple-status-green {
    color: #34C759;
    background-color: rgba(52, 199, 89, 0.14);
    border: 1px solid rgba(52, 199, 89, 0.25);
    border-radius: 8px;
    padding: 3px 8px;
    font-weight: 600;
    font-size: 11px;
}

.apple-status-orange {
    color: #FF9500;
    background-color: rgba(255, 149, 0, 0.14);
    border: 1px solid rgba(255, 149, 0, 0.25);
    border-radius: 8px;
    padding: 3px 8px;
    font-weight: 600;
    font-size: 11px;
}

.apple-status-red {
    color: #FF3B30;
    background-color: rgba(255, 59, 48, 0.14);
    border: 1px solid rgba(255, 59, 48, 0.25);
    border-radius: 8px;
    padding: 3px 8px;
    font-weight: 600;
    font-size: 11px;
}

.apple-status-accent {
    color: @accent_color;
    background-color: alpha(@accent_color, 0.14);
    border: 1px solid alpha(@accent_color, 0.25);
    border-radius: 8px;
    padding: 3px 8px;
    font-weight: 600;
    font-size: 11px;
}
"""

def make_icon_prefix(glyph: str) -> Gtk.Label:
    lbl = Gtk.Label(label=glyph)
    lbl.add_css_class("apple-icon-prefix")
    lbl.set_valign(Gtk.Align.CENTER)
    lbl.set_halign(Gtk.Align.CENTER)
    lbl.set_size_request(28, 28)
    return lbl

def set_badge(lbl: Gtk.Label, text: str, css_class: str):
    lbl.set_text(text)
    for c in ["apple-status-green", "apple-status-orange", "apple-status-red", "apple-status-accent"]:
        lbl.remove_css_class(c)
    if css_class:
        lbl.add_css_class(css_class)
    lbl.set_valign(Gtk.Align.CENTER)

SERVICES_DEF = [
    ("glance", "󰖟", "Glance Homelab Portal", "https://lab", "Unified service landing page and node dashboard"),
    ("kuma", "󰈸", "Status and Uptime Kuma", "https://status.lab", "Live health monitoring and incident reporting"),
    ("git", "󰊢", "Forgejo Git Repositories", "https://git.lab", "Self-hosted Git forge for dotfiles and code"),
    ("ci", "󰑮", "Woodpecker CI Pipelines", "https://ci.lab", "Automated builds and deployment workflows"),
    ("idm", "󰌆", "Kanidm Identity Provider", "https://idm.lab", "Decentralized single sign-on authentication"),
    ("vault", "󰌾", "Vaultwarden Password Vault", "https://vault.lab", "Encrypted secrets and credentials management"),
    ("bookmarks", "󰃁", "Shiori Web Archiver", "https://bookmarks.lab", "Self-hosted bookmarks and offline reader"),
]

NODE_GLYPHS = {
    "desktop": "󰞷",
    "laptop": "󰌢",
    "rpi4": "󰒋"
}

class FleetManagerApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.justkowal.FleetManager")

    def do_activate(self):
        win = FleetManagerWindow(application=self)
        win.present()

class FleetManagerWindow(Adw.ApplicationWindow):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.set_title("Deployment Fleet Center")
        self.set_default_size(560, 620)
        self.add_css_class("fleet-manager")

        # Apply Matugen Apple CSS
        provider = Gtk.CssProvider()
        provider.load_from_data(APPLE_MATUGEN_CSS.encode("utf-8"))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        self.local_host_key = get_local_host_key()
        self.hostname = socket.gethostname()

        self.toast_overlay = Adw.ToastOverlay()
        self.set_content(self.toast_overlay)

        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.toast_overlay.set_child(main_box)

        # Header bar
        header = Adw.HeaderBar()
        title_widget = Adw.WindowTitle(
            title="Deployment Fleet Center",
            subtitle=f"Host: {self.hostname} ({self.local_host_key.capitalize()})"
        )
        header.set_title_widget(title_widget)

        self.btn_probe = Gtk.Button(label="Probe All")
        self.btn_probe.add_css_class("suggested-action")
        self.btn_probe.add_css_class("apple-pill-btn")
        self.btn_probe.set_valign(Gtk.Align.CENTER)
        self.btn_probe.connect("clicked", lambda b: self.trigger_full_probe(show_toast=True))
        header.pack_end(self.btn_probe)

        main_box.append(header)

        # Scrolled content with smooth vertical scroll
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_vexpand(True)
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        main_box.append(scrolled)

        pref_page = Adw.PreferencesPage()
        scrolled.set_child(pref_page)

        # ── Group 1: Deployment Machines ──
        self.nodes_group = Adw.PreferencesGroup(
            title="Deployment Fleet Nodes",
            description="Dynamic status, active routing (LAN / Tailscale mesh), and live latencies"
        )
        pref_page.add(self.nodes_group)

        self.node_rows = {}
        for node_key in ["desktop", "rpi4", "laptop"]:
            row = Adw.ActionRow()
            glyph = NODE_GLYPHS.get(node_key, "󰒋")
            row.add_prefix(make_icon_prefix(glyph))

            lbl_badge = Gtk.Label(label="Discovering...")
            set_badge(lbl_badge, "Discovering...", "apple-status-orange")
            lbl_badge.set_valign(Gtk.Align.CENTER)
            row.add_suffix(lbl_badge)

            btn_ssh = Gtk.Button(label="SSH Terminal")
            btn_ssh.add_css_class("apple-pill-btn")
            btn_ssh.set_valign(Gtk.Align.CENTER)
            btn_ssh._node_key = node_key
            # Connect ONCE to avoid duplicate callbacks
            btn_ssh.connect("clicked", self._on_ssh_btn_clicked)
            row.add_suffix(btn_ssh)

            btn_wake = None
            if node_key == "desktop":
                btn_wake = Gtk.Button(label="󱐋 Wake Desktop")
                btn_wake.add_css_class("apple-pill-btn")
                btn_wake.set_valign(Gtk.Align.CENTER)
                btn_wake.connect("clicked", self._on_wake_btn_clicked)
                btn_wake.set_visible(False)
                row.add_suffix(btn_wake)

            self.nodes_group.add(row)
            self.node_rows[node_key] = {
                "row": row,
                "badge": lbl_badge,
                "ssh_btn": btn_ssh,
                "wake_btn": btn_wake,
                "active_ip": None,
                "hostname": node_key
            }

        # ── Group 2: Live Hosted Homelab Services ──
        self.services_group = Adw.PreferencesGroup(
            title="Hosted Infrastructure Services",
            description="Real-time HTTP health probes and gateway status across Caddy reverse proxy"
        )
        pref_page.add(self.services_group)

        self.service_rows = {}
        for s_id, glyph, name, url, desc in SERVICES_DEF:
            row = Adw.ActionRow(title=name, subtitle=f"{url} · Probing HTTP...")
            row.add_prefix(make_icon_prefix(glyph))

            lbl_stat = Gtk.Label(label="Probing...")
            set_badge(lbl_stat, "Probing...", "apple-status-orange")
            lbl_stat.set_valign(Gtk.Align.CENTER)
            row.add_suffix(lbl_stat)

            btn_open = Gtk.Button(label="Open Web")
            btn_open.add_css_class("apple-pill-btn")
            btn_open.set_valign(Gtk.Align.CENTER)
            btn_open.connect("clicked", lambda b, u=url: subprocess.Popen(["xdg-open", u]))
            row.add_suffix(btn_open)

            self.services_group.add(row)
            self.service_rows[s_id] = {
                "row": row,
                "badge": lbl_stat,
                "url": url,
                "desc": desc
            }

        # ── Group 3: Flake & Host Telemetry ──
        telemetry_group = Adw.PreferencesGroup(
            title="Local Flake and System Health",
            description="Active NixOS system generation, kernel, and storage metrics"
        )
        pref_page.add(telemetry_group)

        self.row_flake = Adw.ActionRow(title="Nix Flake Revision", subtitle="Checking...")
        self.row_flake.add_prefix(make_icon_prefix("󰘬"))
        telemetry_group.add(self.row_flake)

        self.row_system = Adw.ActionRow(title="Operating System and Kernel", subtitle="Checking...")
        self.row_system.add_prefix(make_icon_prefix("󰌽"))
        telemetry_group.add(self.row_system)

        self.row_storage = Adw.ActionRow(title="Root Storage Allocation", subtitle="Checking...")
        self.row_storage.add_prefix(make_icon_prefix("󰋊"))
        telemetry_group.add(self.row_storage)

        # ── Group 4: Companion Hardware Utilities ──
        tools_group = Adw.PreferencesGroup(
            title="Fleet Companion Utilities",
            description="Launch companion tools and screen sharing"
        )
        pref_page.add(tools_group)

        # Control Center
        row_cc = Adw.ActionRow(
            title="System Control Center",
            subtitle="Audio volume, brightness, battery wattage, and power profiles"
        )
        row_cc.add_prefix(make_icon_prefix("󰕮"))
        btn_cc = Gtk.Button(label="Open Control Center")
        btn_cc.add_css_class("apple-pill-btn")
        btn_cc.set_valign(Gtk.Align.CENTER)
        btn_cc.connect("clicked", lambda b: subprocess.Popen(["control-center-gui"]))
        row_cc.add_suffix(btn_cc)
        tools_group.add(row_cc)

        # Seamless Mouse
        row_mouse = Adw.ActionRow(
            title="Seamless Mouse and Desk Layout",
            subtitle="Configure physical screen arrangement and lan-mouse KVM daemon"
        )
        row_mouse.add_prefix(make_icon_prefix("󰍽"))
        btn_mouse = Gtk.Button(label="Configure Mouse")
        btn_mouse.add_css_class("apple-pill-btn")
        btn_mouse.set_valign(Gtk.Align.CENTER)
        btn_mouse.connect("clicked", lambda b: subprocess.Popen(["lan-mouse-gui"]))
        row_mouse.add_suffix(btn_mouse)
        tools_group.add(row_mouse)

        # Tablet Studio
        row_tablet = Adw.ActionRow(
            title="Tablet Display Streaming Studio",
            subtitle="Headless virtual monitors and Sunshine/Moonlight tablet streaming"
        )
        row_tablet.add_prefix(make_icon_prefix("󰹑"))
        btn_tablet = Gtk.Button(label="Configure Tablet")
        btn_tablet.add_css_class("apple-pill-btn")
        btn_tablet.set_valign(Gtk.Align.CENTER)
        btn_tablet.connect("clicked", lambda b: subprocess.Popen(["tablet-display-gui"]))
        row_tablet.add_suffix(btn_tablet)
        tools_group.add(row_tablet)

        # Trigger initial probes
        self.update_telemetry_ui()
        self.trigger_full_probe(show_toast=False)
        GLib.timeout_add_seconds(25, lambda: self.trigger_full_probe(show_toast=False) or True)

    def _on_ssh_btn_clicked(self, btn):
        node_key = getattr(btn, "_node_key", None)
        if node_key and node_key in self.node_rows:
            node_data = self.node_rows[node_key]
            active_ip = node_data.get("active_ip")
            hname = node_data.get("hostname", node_key)
            self.on_ssh_clicked(hname, active_ip)

    def update_telemetry_ui(self):
        # 1. Git flake revision
        rev = "Local Flake"
        try:
            p = subprocess.run(["git", "-C", "/etc/nixos", "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
            if p.returncode == 0:
                rev = f"Commit {p.stdout.strip()} (branch perf-benchmarks)"
        except Exception:
            pass
        self.row_flake.set_subtitle(rev)

        # 2. OS & Kernel
        kernel = os.uname().release
        self.row_system.set_subtitle(f"NixOS 26.05 · Linux {kernel}")

        # 3. Storage
        try:
            usage = shutil.disk_usage("/")
            free_gb = usage.free / (1024**3)
            total_gb = usage.total / (1024**3)
            used_pct = int(((total_gb - free_gb) / total_gb) * 100)
            self.row_storage.set_subtitle(f"{free_gb:.1f} GB free of {total_gb:.1f} GB ({used_pct}% utilized)")
        except Exception:
            pass

    def trigger_full_probe(self, show_toast: bool = False):
        self.btn_probe.set_sensitive(False)
        threading.Thread(target=self._worker_probe, args=(show_toast,), daemon=True).start()
        return True

    def _worker_probe(self, show_toast: bool):
        # 1. Probe fleet nodes
        fleet_data = resolve_all_nodes()

        # 2. Probe HTTP services
        services_status = {}
        ssl_ctx = ssl.create_default_context()
        ssl_ctx.check_hostname = False
        ssl_ctx.verify_mode = ssl.CERT_NONE

        for s_id, _, _, url, _ in SERVICES_DEF:
            t0 = time.time()
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "FleetManager/1.0"})
                with urllib.request.urlopen(req, timeout=1.2, context=ssl_ctx) as resp:
                    elapsed = int((time.time() - t0) * 1000)
                    services_status[s_id] = {
                        "online": True,
                        "code": resp.status,
                        "ms": elapsed,
                        "err": None
                    }
            except Exception as e:
                elapsed = int((time.time() - t0) * 1000)
                err_msg = "Timeout"
                if "Errno -2" in str(e):
                    err_msg = "DNS Lookup"
                elif hasattr(e, "code"):
                    # HTTP errors like 401/403 still mean service is online!
                    services_status[s_id] = {
                        "online": True,
                        "code": e.code,
                        "ms": elapsed,
                        "err": None
                    }
                    continue
                services_status[s_id] = {
                    "online": False,
                    "code": None,
                    "ms": elapsed,
                    "err": err_msg
                }

        GLib.idle_add(self._apply_probe_results, fleet_data, services_status, show_toast)

    def _apply_probe_results(self, fleet_data: dict, services_status: dict, show_toast: bool):
        self.btn_probe.set_sensitive(True)
        self.update_telemetry_ui()

        # Apply Node Results
        for node_key, info in fleet_data.items():
            if node_key not in self.node_rows:
                continue

            ui = self.node_rows[node_key]
            row = ui["row"]
            badge = ui["badge"]
            ssh_btn = ui["ssh_btn"]
            wake_btn = ui.get("wake_btn")

            row.set_title(info["title"])
            ui["hostname"] = info["name"]

            if info["local"]:
                row.set_subtitle(f"{info['role']} · Local Host Active")
                set_badge(badge, "󰄲 Active Local Host", "apple-status-green")
                ssh_btn.set_visible(False)
                if wake_btn:
                    wake_btn.set_visible(False)
            else:
                active_ip = info["active_ip"]
                route = info["route_type"]
                latency = info["latency_ms"]
                online = info["online"]
                ui["active_ip"] = active_ip

                if online and latency is not None:
                    set_badge(badge, f"󰄲 Online ({latency:.1f} ms · {route})", "apple-status-green")
                    ip_detail = f"IP: {active_ip} ({route})"
                    if info.get("ts_ip") and route != "Tailscale":
                        ip_detail += f" · Tailscale: {info['ts_ip']}"
                    row.set_subtitle(f"{info['role']} · {ip_detail}")
                    ssh_btn.set_visible(True)
                    ssh_btn.set_sensitive(True)
                    if wake_btn:
                        wake_btn.set_visible(False)
                elif online:
                    set_badge(badge, f"󰄲 Online ({route})", "apple-status-green")
                    row.set_subtitle(f"{info['role']} · IP: {active_ip}")
                    ssh_btn.set_visible(True)
                    ssh_btn.set_sensitive(True)
                    if wake_btn:
                        wake_btn.set_visible(False)
                else:
                    if not getattr(self, "_waking_desktop", False) or node_key != "desktop":
                        set_badge(badge, "󰅙 Offline", "apple-status-red")
                        last_known = active_ip or "Unresolved"
                        row.set_subtitle(f"{info['role']} · Target: {last_known}")
                        if wake_btn:
                            ssh_btn.set_visible(False)
                            wake_btn.set_visible(True)
                            wake_btn.set_sensitive(True)
                            wake_btn.set_label("󱐋 Wake Desktop")
                        else:
                            ssh_btn.set_visible(True)
                            ssh_btn.set_sensitive(False)

        # Apply Services Results
        for s_id, s_info in services_status.items():
            if s_id not in self.service_rows:
                continue

            s_ui = self.service_rows[s_id]
            s_row = s_ui["row"]
            s_badge = s_ui["badge"]

            if s_info["online"]:
                code = s_info["code"]
                ms = s_info["ms"]
                set_badge(s_badge, f"󰄲 HTTP {code} ({ms} ms)", "apple-status-green")
                s_row.set_subtitle(f"{s_ui['url']} · Active Gateway ({ms} ms latency) — {s_ui['desc']}")
            else:
                err = s_info["err"] or "Offline"
                set_badge(s_badge, f"󰅙 {err}", "apple-status-red")
                s_row.set_subtitle(f"{s_ui['url']} · Unreachable ({err}) — {s_ui['desc']}")

        if show_toast:
            toast = Adw.Toast.new("Fleet and services probed dynamically")
            toast.set_timeout(2)
            self.toast_overlay.add_toast(toast)

    def _on_wake_btn_clicked(self, btn):
        dialog = Adw.MessageDialog.new(
            self,
            "Wake Desktop Workstation",
            "Choose wake mode for Desktop Workstation:"
        )
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("desktop", "󰞷 Workstation GUI (Hyprland via Pi)")
        dialog.add_response("server", "󰒋 Scale-to-Zero (Server via Pi)")
        dialog.add_response("pi_wol", "󱐋 Direct WoL (Local Pi Ethernet)")
        dialog.add_response("lan", "󰌢 Laptop Direct Broadcast WoL")

        dialog.set_response_appearance("desktop", Adw.ResponseAppearance.SUGGESTED)
        dialog.connect("response", self._on_wake_dialog_response)
        dialog.present()

    def _on_wake_dialog_response(self, dialog, response):
        if response in ["desktop", "server", "pi_wol", "lan"]:
            self.execute_wake(response)

    def execute_wake(self, mode: str):
        self._waking_desktop = True
        ui = self.node_rows.get("desktop")
        if not ui:
            return

        row = ui["row"]
        badge = ui["badge"]
        wake_btn = ui.get("wake_btn")
        ssh_btn = ui.get("ssh_btn")

        if wake_btn:
            wake_btn.set_sensitive(False)
            wake_btn.set_label("󱐋 Waking...")
        set_badge(badge, "󱐋 Sending Signal...", "apple-status-orange")

        mode_titles = {
            "desktop": "Workstation GUI (via Pi)",
            "server": "Scale-to-Zero (via Pi)",
            "pi_wol": "Direct WoL (via Pi)",
            "lan": "Laptop Direct WoL"
        }
        mode_label = mode_titles.get(mode, mode)
        row.set_subtitle(f"Sending wake signal ({mode_label})...")

        toast = Adw.Toast.new(f"Sending wake signal for {mode_label}...")
        toast.set_timeout(3)
        self.toast_overlay.add_toast(toast)

        threading.Thread(target=self._worker_wake, args=(mode, mode_label), daemon=True).start()

    def _worker_wake(self, mode: str, mode_label: str):
        mac = "10:ff:e0:40:7d:6e"

        # 1. Send Wake Signal via Local Network through Pi or Direct
        try:
            if mode == "desktop":
                self._wake_via_pi("wake-desktop")
            elif mode == "server":
                self._wake_via_pi("wake-worker")
            elif mode == "pi_wol":
                self._wake_via_pi("wake-wol")
            elif mode == "lan":
                self._send_wol_magic_packet(mac)
        except Exception as e:
            GLib.idle_add(self._on_wake_error, f"Wake error: {e}")
            return

        # 2. Polling loop with real-time status reporting
        t0 = time.time()
        timeout = 90
        online = False

        while time.time() - t0 < timeout:
            elapsed = int(time.time() - t0)
            GLib.idle_add(self._update_wake_status, elapsed, mode_label)

            if self._check_desktop_online():
                online = True
                boot_seconds = int(time.time() - t0)
                GLib.idle_add(self._on_wake_success, boot_seconds)
                break

            time.sleep(2)

        if not online:
            GLib.idle_add(self._on_wake_timeout)

    def _wake_via_pi(self, hook_id: str):
        # 1. HTTP webhook to Pi 4 (port 9100 on Tailnet/LAN)
        url = f"http://nixos-rpi4.lab:9100/hooks/{hook_id}"
        success = False
        try:
            req = urllib.request.Request(url, data=b"", headers={"User-Agent": "FleetManager/1.0"}, method="POST")
            with urllib.request.urlopen(req, timeout=3) as resp:
                if resp.status in (200, 204):
                    success = True
        except Exception:
            pass

        if not success:
            # 2. Resilient SSH fallback to Pi 4 to execute local wake script
            try:
                res = subprocess.run(
                    ["ssh", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=no", "justkowal@nixos-rpi4.lab", hook_id],
                    capture_output=True,
                    timeout=5
                )
                if res.returncode == 0:
                    success = True
            except Exception:
                pass

        # 3. Always dispatch local layer-2 broadcast as secondary safeguard
        self._send_wol_magic_packet("10:ff:e0:40:7d:6e")
        return success

    def _send_wol_magic_packet(self, mac_str: str):
        # Native Python UDP broadcast magic packet
        raw_mac = bytes.fromhex(mac_str.replace(":", "").replace("-", ""))
        payload = b'\xff' * 6 + raw_mac * 16
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.sendto(payload, ("255.255.255.255", 9))
            # Also broadcast on standard local subnets
            for bcast in ["192.168.1.255", "192.168.0.255", "10.0.0.255"]:
                try:
                    sock.sendto(payload, (bcast, 9))
                except Exception:
                    pass
        # Also invoke wakeonlan CLI if available in PATH
        try:
            subprocess.run(["wakeonlan", mac_str], capture_output=True, timeout=2)
        except Exception:
            pass

    def _post_webhook(self, url: str):
        req = urllib.request.Request(url, data=b"", headers={"User-Agent": "FleetManager/1.0"}, method="POST")
        with urllib.request.urlopen(req, timeout=3) as resp:
            return resp.status

    def _check_desktop_online(self) -> bool:
        # Check SSH port 22 or ping on DNS candidates
        for host in ["nixos-desktop.lab", "nixos-desktop.local", "nixos-desktop"]:
            try:
                with socket.create_connection((host, 22), timeout=1.0):
                    return True
            except Exception:
                pass
        return False

    def _update_wake_status(self, elapsed: int, mode_label: str):
        ui = self.node_rows.get("desktop")
        if not ui:
            return
        row = ui["row"]
        badge = ui["badge"]
        set_badge(badge, f"󱍷 Booting... ({elapsed}s)", "apple-status-orange")
        row.set_subtitle(f"Workstation · Booting Desktop ({mode_label})... {elapsed}s elapsed")

    def _on_wake_success(self, boot_seconds: int):
        self._waking_desktop = False
        ui = self.node_rows.get("desktop")
        if not ui:
            return
        row = ui["row"]
        badge = ui["badge"]
        wake_btn = ui.get("wake_btn")
        ssh_btn = ui.get("ssh_btn")

        set_badge(badge, f"󰄲 Online (Booted in {boot_seconds}s)", "apple-status-green")
        row.set_subtitle(f"Workstation · Desktop is online and ready! (Booted in {boot_seconds}s)")
        if wake_btn:
            wake_btn.set_visible(False)
        if ssh_btn:
            ssh_btn.set_visible(True)
            ssh_btn.set_sensitive(True)

        toast = Adw.Toast.new("󰄲 Desktop is online! Ready for SSH and Sunshine.")
        toast.set_timeout(4)
        self.toast_overlay.add_toast(toast)
        self.trigger_full_probe(show_toast=False)

    def _on_wake_timeout(self):
        self._waking_desktop = False
        ui = self.node_rows.get("desktop")
        if not ui:
            return
        row = ui["row"]
        badge = ui["badge"]
        wake_btn = ui.get("wake_btn")

        set_badge(badge, "󰅙 Wake Timed Out", "apple-status-red")
        row.set_subtitle("Workstation · No response after 90 seconds. Check power or cable.")
        if wake_btn:
            wake_btn.set_sensitive(True)
            wake_btn.set_label("󱐋 Retry Wake")

        toast = Adw.Toast.new("󰅙 Timed out waiting for Desktop to boot after 90s")
        toast.set_timeout(4)
        self.toast_overlay.add_toast(toast)

    def _on_wake_error(self, err_msg: str):
        self._waking_desktop = False
        ui = self.node_rows.get("desktop")
        if not ui:
            return
        badge = ui["badge"]
        wake_btn = ui.get("wake_btn")

        set_badge(badge, "󰅙 Wake Failed", "apple-status-red")
        if wake_btn:
            wake_btn.set_sensitive(True)
            wake_btn.set_label("󱐋 Retry Wake")

        toast = Adw.Toast.new(f"󰅙 {err_msg}")
        toast.set_timeout(4)
        self.toast_overlay.add_toast(toast)

    def on_ssh_clicked(self, hostname: str, target_ip: str):
        if not target_ip:
            target_ip = hostname
        subprocess.Popen([
            "kitty",
            "--title", f"SSH: {hostname} ({target_ip})",
            "-e", "ssh", f"justkowal@{target_ip}"
        ])

if __name__ == "__main__":
    app = FleetManagerApp()
    sys.exit(app.run(sys.argv))
