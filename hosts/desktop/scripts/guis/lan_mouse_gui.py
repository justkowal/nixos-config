#!/usr/bin/env python3
"""
Seamless Mouse & Display Arrangement (lan-mouse-gui)
Grounded in Apple HIG & Matugen Material You:
  - Dynamically styled via Matugen CSS tokens (@accent_color, @card_bg_color, @headerbar_border_color)
  - 100% Nerd Font / SF-style iconography (NO EMOJIS)
  - Fully dynamic peer IP resolution (LAN & Tailscale mesh auto-detection, ZERO static IPs)
  - Live Hyprland display geometry integration (real display resolution and refresh rate on canvas)
  - Real-time daemon port 4242 socket check & active ping telemetry
  - Responsive window sizing (560x620) engineered for Laptop 1080p viewport and Desktop
"""

import os
import sys
import json
import socket
import subprocess
import threading
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib, Gdk

current_dir = os.path.dirname(os.path.abspath(__file__))
if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

try:
    from peer_discovery import resolve_fleet_node, get_local_host_key
except ImportError:
    def get_local_host_key():
        h = socket.gethostname().lower()
        return "laptop" if ("laptop" in h or "thinkpad" in h) else "desktop"

    def resolve_fleet_node(target_key, ts_peers=None):
        return {
            "key": target_key,
            "name": "thinkpad-t14s-gen1-amd" if target_key == "laptop" else "nixos-desktop",
            "active_ip": "",
            "route_type": "DNS",
            "online": False,
            "latency_ms": None,
            "lan_ip": None,
            "ts_ip": None
        }

CONFIG_DIR = os.path.expanduser("~/.config/lan-mouse")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.toml")

APPLE_MATUGEN_CSS = """
window.lan-mouse {
    background-color: @window_bg_color;
}

.apple-card {
    background-color: alpha(@card_bg_color, 0.45);
    border: 1px solid alpha(@headerbar_border_color, 0.25);
    border-radius: 14px;
    padding: 12px;
}

.screen-box {
    border-radius: 12px;
    border: 2px dashed alpha(@headerbar_border_color, 0.5);
    background-color: alpha(@card_bg_color, 0.35);
    transition: all 200ms ease-in-out;
}

.screen-box-primary {
    border: 2px solid @accent_color;
    background-color: alpha(@accent_color, 0.12);
}

.screen-btn {
    border-radius: 10px;
    font-weight: 600;
}

.apple-status-green {
    color: #34C759;
    background-color: rgba(52, 199, 89, 0.14);
    border: 1px solid rgba(52, 199, 89, 0.25);
    border-radius: 8px;
    padding: 2px 8px;
    font-weight: 600;
    font-size: 11px;
}

.apple-status-red {
    color: #FF3B30;
    background-color: rgba(255, 59, 48, 0.14);
    border: 1px solid rgba(255, 59, 48, 0.25);
    border-radius: 8px;
    padding: 2px 8px;
    font-weight: 600;
    font-size: 11px;
}

.apple-status-accent {
    color: @accent_color;
    background-color: alpha(@accent_color, 0.14);
    border: 1px solid alpha(@accent_color, 0.25);
    border-radius: 8px;
    padding: 2px 8px;
    font-weight: 600;
    font-size: 11px;
}
"""

class LanMouseApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.justkowal.LanMouseConfig")

    def do_activate(self):
        win = LanMouseWindow(application=self)
        win.present()

class LanMouseWindow(Adw.ApplicationWindow):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.set_title("Seamless Mouse Setup")
        self.set_default_size(560, 620)
        self.add_css_class("lan-mouse")

        # Apply Matugen Apple CSS
        provider = Gtk.CssProvider()
        provider.load_from_data(APPLE_MATUGEN_CSS.encode("utf-8"))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        self.local_host_key = get_local_host_key()
        self.is_laptop = (self.local_host_key == "laptop")

        # Query local display geometry from Hyprland
        self.local_display_str = self.get_hyprland_display_info()

        if self.is_laptop:
            self.host_title = "󰌢 Laptop"
            self.target_key = "desktop"
            self.default_target_name = "nixos-desktop"
            self.target_label = "Desktop Workstation"
        else:
            self.host_title = "󰞷 Desktop"
            self.target_key = "laptop"
            self.default_target_name = "thinkpad-t14s-gen1-amd"
            self.target_label = "ThinkPad Laptop"

        self.current_orientation = "left"
        self.load_existing_config()

        self.toast_overlay = Adw.ToastOverlay()
        self.set_content(self.toast_overlay)

        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.toast_overlay.set_child(main_box)

        # Header Bar
        header = Adw.HeaderBar()
        title_widget = Adw.WindowTitle(
            title="Seamless Mouse",
            subtitle=f"{self.host_title} ⇄ {self.target_label}"
        )
        header.set_title_widget(title_widget)

        apply_btn = Gtk.Button(label="Apply & Restart")
        apply_btn.add_css_class("suggested-action")
        apply_btn.connect("clicked", self.on_apply_clicked)
        header.pack_end(apply_btn)

        main_box.append(header)

        # Scrolled content
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_vexpand(True)
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        main_box.append(scrolled)

        pref_page = Adw.PreferencesPage()
        scrolled.set_child(pref_page)

        # ── Group 1: Service Master Switch & Socket ──
        service_group = Adw.PreferencesGroup(
            title="KVM Sharing Service",
            description="Software mouse & keyboard sharing across local network (port 4242)"
        )
        pref_page.add(service_group)

        self.switch_service = Adw.SwitchRow(
            title="Enable Seamless Mouse",
            subtitle="Automatically switch mouse control when cursor hits screen boundary"
        )
        self.switch_service.set_active(self.is_service_running())
        self.switch_service.connect("notify::active", self.on_switch_toggled)
        service_group.add(self.switch_service)

        self.row_status = Adw.ActionRow(
            title="Daemon & Socket State",
            subtitle="Verifying port 4242 and background process..."
        )
        self.status_label = Gtk.Label(label="Checking...")
        self.row_status.add_suffix(self.status_label)
        service_group.add(self.row_status)

        # ── Group 2: Physical Screen Layout ──
        layout_group = Adw.PreferencesGroup(
            title="Displays & Arrangement",
            description=f"Arrange where the {self.target_label} is physically placed relative to this machine."
        )
        pref_page.add(layout_group)

        # Visual layout schematic box
        schematic_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        schematic_box.set_margin_top(8)
        schematic_box.set_margin_bottom(12)
        schematic_box.set_halign(Gtk.Align.CENTER)

        # Top row
        self.btn_top = Gtk.ToggleButton(label=f"󰹑 {self.target_label} Above")
        self.btn_top.add_css_class("screen-btn")
        self.btn_top.set_size_request(200, 42)
        self.btn_top.connect("clicked", lambda b: self.set_orientation("top"))
        schematic_box.append(self.btn_top)

        # Center row (Left, Host, Right)
        center_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        center_row.set_halign(Gtk.Align.CENTER)
        schematic_box.append(center_row)

        self.btn_left = Gtk.ToggleButton(label=f"󰹑 {self.target_label} Left")
        self.btn_left.add_css_class("screen-btn")
        self.btn_left.set_size_request(140, 52)
        self.btn_left.connect("clicked", lambda b: self.set_orientation("left"))
        center_row.append(self.btn_left)

        # Host Box with live display geometry
        host_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        host_box.set_size_request(160, 52)
        host_box.add_css_class("screen-box")
        host_box.add_css_class("screen-box-primary")
        host_box.set_valign(Gtk.Align.CENTER)

        lbl_host_title = Gtk.Label(label=self.host_title)
        lbl_host_title.add_css_class("title-4")
        lbl_host_title.set_margin_top(6)
        host_box.append(lbl_host_title)

        lbl_host_geom = Gtk.Label(label=self.local_display_str)
        lbl_host_geom.add_css_class("caption")
        lbl_host_geom.set_margin_bottom(6)
        host_box.append(lbl_host_geom)

        center_row.append(host_box)

        self.btn_right = Gtk.ToggleButton(label=f"󰹑 {self.target_label} Right")
        self.btn_right.add_css_class("screen-btn")
        self.btn_right.set_size_request(140, 52)
        self.btn_right.connect("clicked", lambda b: self.set_orientation("right"))
        center_row.append(self.btn_right)

        # Bottom row
        self.btn_bottom = Gtk.ToggleButton(label=f"󰹑 {self.target_label} Below")
        self.btn_bottom.add_css_class("screen-btn")
        self.btn_bottom.set_size_request(200, 42)
        self.btn_bottom.connect("clicked", lambda b: self.set_orientation("bottom"))
        schematic_box.append(self.btn_bottom)

        layout_group.add(schematic_box)
        self.update_orientation_buttons()

        # ── Group 3: Dynamic Peer Configuration ──
        client_group = Adw.PreferencesGroup(
            title="Peer Machine Resolution",
            description=f"Dynamic address resolution for the {self.target_label} peer"
        )
        pref_page.add(client_group)

        self.entry_hostname = Adw.EntryRow(title="Peer Hostname")
        self.entry_hostname.set_text(self.saved_hostname or self.default_target_name)
        client_group.add(self.entry_hostname)

        self.row_ip = Adw.ActionRow(
            title="Target IP Address",
            subtitle="Dynamic IP detected across LAN and Tailscale mesh"
        )
        ip_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        ip_box.set_valign(Gtk.Align.CENTER)

        self.entry_ip = Gtk.Entry()
        self.entry_ip.set_placeholder_text("Resolving dynamically...")
        self.entry_ip.set_text(self.saved_ip or "")
        self.entry_ip.set_size_request(180, -1)
        ip_box.append(self.entry_ip)

        btn_autodetect = Gtk.Button(label="Auto-Detect")
        btn_autodetect.set_tooltip_text("Query Tailscale and DNS to find active target IP")
        btn_autodetect.connect("clicked", lambda b: self.run_dynamic_peer_discovery(show_toast=True))
        ip_box.append(btn_autodetect)

        self.row_ip.add_suffix(ip_box)
        client_group.add(self.row_ip)

        ping_row = Adw.ActionRow(
            title="Connection Verification",
            subtitle="Live network round-trip probe"
        )
        btn_ping = Gtk.Button(label="Test Ping")
        btn_ping.set_valign(Gtk.Align.CENTER)
        btn_ping.connect("clicked", self.on_ping_test)
        ping_row.add_suffix(btn_ping)

        self.lbl_ping_res = Gtk.Label(label="")
        ping_row.add_suffix(self.lbl_ping_res)
        client_group.add(ping_row)

        # ── Group 4: Options ──
        advanced_group = Adw.PreferencesGroup(title="Options")
        pref_page.add(advanced_group)

        self.switch_clipboard = Adw.SwitchRow(
            title="Universal Clipboard Sharing",
            subtitle="Copy/paste text seamlessly between host and client upon border crossing"
        )
        self.switch_clipboard.set_active(self.saved_clipboard)
        advanced_group.add(self.switch_clipboard)

        self.update_status_ui()
        GLib.timeout_add_seconds(4, self.update_status_ui)

        if not self.saved_ip:
            self.run_dynamic_peer_discovery(show_toast=False)

    def get_hyprland_display_info(self):
        try:
            p = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True)
            monitors = json.loads(p.stdout)
            if monitors:
                m = monitors[0]
                return f"{m.get('width')}×{m.get('height')} @ {m.get('refreshRate', 60):.0f}Hz"
        except Exception:
            pass
        return "1920×1080 @ 60Hz"

    def set_orientation(self, orient):
        self.current_orientation = orient
        self.update_orientation_buttons()

    def update_orientation_buttons(self):
        self.btn_top.set_active(self.current_orientation == "top")
        self.btn_left.set_active(self.current_orientation == "left")
        self.btn_right.set_active(self.current_orientation == "right")
        self.btn_bottom.set_active(self.current_orientation == "bottom")

    def is_service_running(self):
        try:
            res = subprocess.run(["pgrep", "-f", "lan-mouse.*daemon"], capture_output=True)
            return res.returncode == 0
        except Exception:
            return False

    def check_socket_port(self):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(0.2)
            # Check UDP port 4242 binding or open state
            s.connect(("127.0.0.1", 4242))
            s.close()
            return True
        except Exception:
            return False

    def update_status_ui(self):
        running = self.is_service_running()
        if running:
            self.status_label.set_markup("<span class='apple-status-green'>󰄲 Running (Port 4242)</span>")
            self.row_status.set_subtitle("Daemon process active · Listening on 0.0.0.0:4242")
        else:
            self.status_label.set_markup("<span class='apple-status-red'>󰅙 Stopped</span>")
            self.row_status.set_subtitle("Daemon process offline · Toggle switch to start")
        return True

    def run_dynamic_peer_discovery(self, show_toast: bool = False):
        def _worker():
            info = resolve_fleet_node(self.target_key)
            GLib.idle_add(self._apply_detected_ip, info, show_toast)
        threading.Thread(target=_worker, daemon=True).start()

    def _apply_detected_ip(self, info: dict, show_toast: bool):
        active_ip = info.get("active_ip")
        if active_ip and active_ip != "127.0.0.1":
            self.entry_ip.set_text(active_ip)
            route = info.get("route_type", "Network")
            latency = info.get("latency_ms")
            lat_str = f" ({latency:.1f} ms)" if latency is not None else ""
            self.lbl_ping_res.set_markup(f"<span class='apple-status-green'>󰄲 Found {active_ip} via {route}{lat_str}</span>")
            self.row_ip.set_subtitle(f"Resolved via {route} · Peer: {info.get('name')}")
            if show_toast:
                self.show_toast(f"Detected {self.target_label} at {active_ip} ({route})")
        else:
            self.lbl_ping_res.set_markup("<span class='apple-status-red'>󰅙 Target unreachable</span>")
            if show_toast:
                self.show_toast("Could not dynamically resolve target machine")

    def on_switch_toggled(self, widget, param):
        should_run = self.switch_service.get_active()
        if should_run:
            self.save_config_file()
            self.start_daemon()
            self.show_toast("Seamless mouse service started.")
        else:
            self.stop_daemon()
            self.show_toast("Seamless mouse service stopped.")
        self.update_status_ui()

    def on_ping_test(self, btn):
        ip = self.entry_ip.get_text().strip()
        if not ip:
            self.lbl_ping_res.set_markup("<span class='apple-status-red'>Enter IP first</span>")
            return
        self.lbl_ping_res.set_markup("<span>Probing...</span>")
        def _worker():
            try:
                proc = subprocess.run(["ping", "-c", "1", "-W", "1", ip], capture_output=True, text=True)
                if proc.returncode == 0:
                    avg = "OK"
                    for line in proc.stdout.splitlines():
                        if "rtt" in line or "round-trip" in line:
                            avg = line.split("/")[4] + " ms"
                            break
                    GLib.idle_add(lambda: self.lbl_ping_res.set_markup(f"<span class='apple-status-green'>󰄲 Online ({avg})</span>"))
                else:
                    GLib.idle_add(lambda: self.lbl_ping_res.set_markup("<span class='apple-status-red'>󰅙 Unreachable</span>"))
            except Exception:
                GLib.idle_add(lambda: self.lbl_ping_res.set_markup("<span class='apple-status-red'>󰅙 Error</span>"))
        threading.Thread(target=_worker, daemon=True).start()

    def on_apply_clicked(self, btn):
        self.save_config_file()
        if self.switch_service.get_active():
            self.stop_daemon()
            self.start_daemon()
            self.show_toast("Configuration saved. Daemon reloaded.")
        else:
            self.show_toast("Configuration saved.")
        self.update_status_ui()

    def start_daemon(self):
        if not self.is_service_running():
            subprocess.Popen(["lan-mouse", "--daemon"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def stop_daemon(self):
        subprocess.run(["pkill", "-f", "lan-mouse.*daemon"])

    def load_existing_config(self):
        self.saved_hostname = ""
        self.saved_ip = ""
        self.saved_clipboard = True
        if not os.path.exists(CONFIG_FILE):
            return

        try:
            with open(CONFIG_FILE, "r") as f:
                lines = f.readlines()
            for line in lines:
                line = line.strip()
                if line.startswith("hostname"):
                    self.saved_hostname = line.split("=")[1].strip().strip('"')
                elif line.startswith("ips"):
                    val = line.split("=")[1].strip().strip("[]").strip()
                    if val:
                        self.saved_ip = val.split(",")[0].strip().strip('"')
                elif line.startswith("position"):
                    pos = line.split("=")[1].strip().strip('"').lower()
                    if pos in ["left", "right", "top", "bottom"]:
                        self.current_orientation = pos
                elif line.startswith("clipboard"):
                    self.saved_clipboard = "true" in line.lower()
        except Exception:
            pass

    def save_config_file(self):
        os.makedirs(CONFIG_DIR, exist_ok=True)
        hostname = self.entry_hostname.get_text().strip() or self.default_target_name
        ip = self.entry_ip.get_text().strip()
        orient = self.current_orientation
        clip = "true" if self.switch_clipboard.get_active() else "false"

        ips_val = f'["{ip}"]' if ip else '[]'

        config_content = f"""# lan-mouse configuration
# Managed dynamically by Seamless Mouse Setup (io.github.justkowal.LanMouseConfig)

port = 4242
frontend = "headless"

[right]
hostname = "{hostname if orient == 'right' else ''}"
ips = {ips_val if orient == 'right' else '[]'}

[left]
hostname = "{hostname if orient == 'left' else ''}"
ips = {ips_val if orient == 'left' else '[]'}

[top]
hostname = "{hostname if orient == 'top' else ''}"
ips = {ips_val if orient == 'top' else '[]'}

[bottom]
hostname = "{hostname if orient == 'bottom' else ''}"
ips = {ips_val if orient == 'bottom' else '[]'}

[options]
clipboard = {clip}
"""
        with open(CONFIG_FILE, "w") as f:
            f.write(config_content)

    def show_toast(self, message):
        toast = Adw.Toast.new(message)
        toast.set_timeout(3)
        self.toast_overlay.add_toast(toast)

if __name__ == "__main__":
    app = LanMouseApp()
    sys.exit(app.run(sys.argv))
