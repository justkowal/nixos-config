#!/usr/bin/env python3
"""
Seamless Mouse Setup (lan-mouse GUI)
Grounded in Apple HIG & Matugen Material You:
  - Dynamically themed via Matugen CSS tokens (@accent_color, @card_bg_color, @headerbar_border_color)
  - Pure Nerd Font / SF-style iconography (NO EMOJIS)
  - Clean display arrangement schematic resembling macOS Displays / Universal Control
  - Bidirectional host awareness (adapts dynamically to Desktop or Laptop host)
  - Responsive hit targets and in-app toast feedback
"""

import os
import sys
import socket
import subprocess
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib, Gdk

CONFIG_DIR = os.path.expanduser("~/.config/lan-mouse")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.toml")

APPLE_MATUGEN_CSS = """
.apple-card {
    background-color: alpha(@card_bg_color, 0.45);
    border: 1px solid alpha(@headerbar_border_color, 0.25);
    border-radius: 14px;
    padding: 12px;
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

.screen-box {
    border-radius: 12px;
    border: 2px solid alpha(@headerbar_border_color, 0.35);
    background-color: alpha(@card_bg_color, 0.50);
    transition: all 200ms ease;
}

.screen-box-primary {
    border: 2px solid @accent_color;
    background-color: alpha(@accent_color, 0.15);
}

.screen-btn {
    border-radius: 12px;
    padding: 10px 16px;
    font-weight: 600;
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
        self.set_default_size(700, 760)

        # Apply Matugen Apple CSS
        provider = Gtk.CssProvider()
        provider.load_from_data(APPLE_MATUGEN_CSS.encode("utf-8"))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        self.hostname = socket.gethostname()
        self.is_laptop = "laptop" in self.hostname or "thinkpad" in self.hostname

        # Host and target machine defaults
        if self.is_laptop:
            self.host_title = "󰌢 Laptop (Local)"
            self.default_target_name = "nixos-desktop"
            self.default_target_ip = "192.168.1.127"
            self.target_label = "Desktop Workstation"
        else:
            self.host_title = "󰞷 Desktop (Local Workstation)"
            self.default_target_name = "thinkpad-t14s-gen1-amd"
            self.default_target_ip = "192.168.1.20"
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
            subtitle="Cross-Machine KVM & Universal Control"
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
        main_box.append(scrolled)

        pref_page = Adw.PreferencesPage()
        scrolled.set_child(pref_page)

        # ── Group 1: Service Master Switch ──
        service_group = Adw.PreferencesGroup(
            title="KVM Sharing Service",
            description="Software mouse & keyboard sharing across local network (port 4242)"
        )
        pref_page.add(service_group)

        self.switch_service = Adw.SwitchRow(
            title="Enable Seamless Mouse",
            subtitle="Automatically share mouse across screens when cursor reaches display boundary"
        )
        self.switch_service.set_active(self.is_service_running())
        self.switch_service.connect("notify::active", self.on_switch_toggled)
        service_group.add(self.switch_service)

        self.row_status = Adw.ActionRow(title="Daemon Status")
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
        schematic_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        schematic_box.set_margin_top(12)
        schematic_box.set_margin_bottom(16)
        schematic_box.set_halign(Gtk.Align.CENTER)

        # Top row
        self.btn_top = Gtk.ToggleButton(label=f"󰹑 {self.target_label} Above")
        self.btn_top.add_css_class("screen-btn")
        self.btn_top.set_size_request(220, 48)
        self.btn_top.connect("clicked", lambda b: self.set_orientation("top"))
        schematic_box.append(self.btn_top)

        # Center row (Left, Host, Right)
        center_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        schematic_box.append(center_row)

        self.btn_left = Gtk.ToggleButton(label=f"󰹑 {self.target_label} Left")
        self.btn_left.add_css_class("screen-btn")
        self.btn_left.set_size_request(160, 56)
        self.btn_left.connect("clicked", lambda b: self.set_orientation("left"))
        center_row.append(self.btn_left)

        host_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        host_box.set_size_request(180, 56)
        host_box.add_css_class("screen-box")
        host_box.add_css_class("screen-box-primary")
        host_box.set_valign(Gtk.Align.CENTER)
        lbl_host = Gtk.Label(label=self.host_title)
        lbl_host.add_css_class("title-4")
        lbl_host.set_margin_top(14)
        lbl_host.set_margin_bottom(14)
        host_box.append(lbl_host)
        center_row.append(host_box)

        self.btn_right = Gtk.ToggleButton(label=f"󰹑 {self.target_label} Right")
        self.btn_right.add_css_class("screen-btn")
        self.btn_right.set_size_request(160, 56)
        self.btn_right.connect("clicked", lambda b: self.set_orientation("right"))
        center_row.append(self.btn_right)

        # Bottom row
        self.btn_bottom = Gtk.ToggleButton(label=f"󰹑 {self.target_label} Below")
        self.btn_bottom.add_css_class("screen-btn")
        self.btn_bottom.set_size_request(220, 48)
        self.btn_bottom.connect("clicked", lambda b: self.set_orientation("bottom"))
        schematic_box.append(self.btn_bottom)

        layout_group.add(schematic_box)
        self.update_orientation_buttons()

        # ── Group 3: Target Machine ──
        client_group = Adw.PreferencesGroup(
            title="Peer Machine Configuration",
            description=f"Network address for the {self.target_label} peer running lan-mouse"
        )
        pref_page.add(client_group)

        self.entry_hostname = Adw.EntryRow(title="Peer Hostname")
        self.entry_hostname.set_text(self.saved_hostname or self.default_target_name)
        client_group.add(self.entry_hostname)

        self.entry_ip = Adw.EntryRow(title="Peer IP Address")
        self.entry_ip.set_text(self.saved_ip or self.default_target_ip)
        client_group.add(self.entry_ip)

        ping_row = Adw.ActionRow(
            title="Connection Verification",
            subtitle="Probe network latency to peer machine"
        )
        btn_ping = Gtk.Button(label="Test Connection")
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
        GLib.timeout_add_seconds(3, self.update_status_ui)

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

    def update_status_ui(self):
        running = self.is_service_running()
        if running:
            self.status_label.set_markup("<span class='apple-status-green'>󰄲 Running (Port 4242)</span>")
        else:
            self.status_label.set_markup("<span class='apple-status-red'>󰅙 Stopped</span>")
        return True

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
        GLib.idle_add(self._run_ping, ip)

    def _run_ping(self, ip):
        try:
            proc = subprocess.run(["ping", "-c", "1", "-W", "1", ip], capture_output=True, text=True)
            if proc.returncode == 0:
                for line in proc.stdout.splitlines():
                    if "rtt" in line or "round-trip" in line:
                        avg = line.split("/")[4]
                        self.lbl_ping_res.set_markup(f"<span class='apple-status-green'>󰄲 Online ({avg} ms)</span>")
                        return False
                self.lbl_ping_res.set_markup("<span class='apple-status-green'>󰄲 Online</span>")
            else:
                self.lbl_ping_res.set_markup("<span class='apple-status-red'>󰅙 Unreachable</span>")
        except Exception:
            self.lbl_ping_res.set_markup("<span class='apple-status-red'>󰅙 Error</span>")
        return False

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
        ip = self.entry_ip.get_text().strip() or self.default_target_ip
        orient = self.current_orientation
        clip = "true" if self.switch_clipboard.get_active() else "false"

        config_content = f"""# lan-mouse configuration
# Managed by Seamless Mouse Setup (io.github.justkowal.LanMouseConfig)

port = 4242
frontend = "headless"

[right]
hostname = "{hostname if orient == 'right' else ''}"
ips = {f'["{ip}"]' if orient == 'right' else '[]'}

[left]
hostname = "{hostname if orient == 'left' else ''}"
ips = {f'["{ip}"]' if orient == 'left' else '[]'}

[top]
hostname = "{hostname if orient == 'top' else ''}"
ips = {f'["{ip}"]' if orient == 'top' else '[]'}

[bottom]
hostname = "{hostname if orient == 'bottom' else ''}"
ips = {f'["{ip}"]' if orient == 'bottom' else '[]'}

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
