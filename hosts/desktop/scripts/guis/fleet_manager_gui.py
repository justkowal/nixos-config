#!/usr/bin/env python3
"""
Deployment Fleet Center (fleet-manager-gui)
Grounded in Apple HIG & Matugen Material You:
  - Dynamically themed via Matugen CSS tokens (@accent_color, @card_bg_color, @headerbar_border_color)
  - Pure Nerd Font / SF-style iconography (NO EMOJIS)
  - Dynamic local vs remote machine detection
  - Grouped modular preferences cards
  - Instant in-app feedback via Adw.Toast
"""

import os
import sys
import socket
import subprocess
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib, Gdk

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

.apple-status-orange {
    color: #FF9500;
    background-color: rgba(255, 149, 0, 0.14);
    border: 1px solid rgba(255, 149, 0, 0.25);
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

SERVICES = [
    ("󰖟 Glance Homelab Portal", "https://lab", "Unified service landing page and node dashboard"),
    ("󰈸 Status & Uptime Kuma", "https://status.lab", "Live health monitoring and incident reporting"),
    ("󰊢 Forgejo Git Repositories", "https://git.lab", "Self-hosted Git forge for dotfiles and code"),
    ("󰑮 Woodpecker CI Pipelines", "https://ci.lab", "Automated builds and deployment workflows"),
    ("󰌆 Kanidm Identity Provider", "https://idm.lab", "Decentralized single sign-on authentication"),
    ("󰌾 Vaultwarden Password Vault", "https://vault.lab", "Encrypted secrets and credentials management"),
    ("󰃁 Shiori Web Archiver", "https://bookmarks.lab", "Self-hosted bookmarks and offline reader"),
]

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
        self.set_default_size(740, 800)

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

        self.toast_overlay = Adw.ToastOverlay()
        self.set_content(self.toast_overlay)

        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.toast_overlay.set_child(main_box)

        # Header bar
        header = Adw.HeaderBar()
        title_widget = Adw.WindowTitle(
            title="Deployment Fleet Center",
            subtitle=f"Host: {self.hostname} · Multi-Node Management"
        )
        header.set_title_widget(title_widget)

        btn_probe = Gtk.Button(label="Probe Fleet")
        btn_probe.add_css_class("suggested-action")
        btn_probe.connect("clicked", lambda b: self.run_fleet_probe())
        header.pack_end(btn_probe)

        main_box.append(header)

        # Content in ScrolledWindow
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_vexpand(True)
        main_box.append(scrolled)

        pref_page = Adw.PreferencesPage()
        scrolled.set_child(pref_page)

        # ── Group 1: Nodes Overview ──
        nodes_group = Adw.PreferencesGroup(
            title="Deployment Machines",
            description="Active systems in this NixOS configuration flake"
        )
        pref_page.add(nodes_group)

        # Node 1: Desktop Workstation
        self.row_desktop = Adw.ActionRow(
            title="󰞷 nixos-desktop (Workstation)",
            subtitle="Ryzen 7 5700X · AMD RX 6700 XT · ROCm HIP Accelerated"
        )
        if not self.is_laptop:
            lbl_desktop_stat = Gtk.Label(label="󰄲 Active Local Host")
            lbl_desktop_stat.add_css_class("apple-status-green")
            self.row_desktop.add_suffix(lbl_desktop_stat)
        else:
            self.lbl_desk_stat = Gtk.Label(label="Probing...")
            self.row_desktop.add_suffix(self.lbl_desk_stat)
            btn_ssh_desk = Gtk.Button(label="SSH Terminal")
            btn_ssh_desk.set_valign(Gtk.Align.CENTER)
            btn_ssh_desk.connect("clicked", lambda b: subprocess.Popen(["kitty", "--title", "SSH: nixos-desktop", "-e", "ssh", "justkowal@192.168.1.127"]))
            self.row_desktop.add_suffix(btn_ssh_desk)
        nodes_group.add(self.row_desktop)

        # Node 2: RPi4 Homelab Server
        self.row_rpi4 = Adw.ActionRow(
            title="󰒋 nixos-rpi4 (Homelab Core Server)",
            subtitle="192.168.1.22 · Caddy Reverse Proxy · DNS & Core Services"
        )
        self.lbl_rpi_stat = Gtk.Label(label="Probing...")
        self.row_rpi4.add_suffix(self.lbl_rpi_stat)
        btn_ssh_rpi = Gtk.Button(label="SSH Terminal")
        btn_ssh_rpi.set_valign(Gtk.Align.CENTER)
        btn_ssh_rpi.connect("clicked", lambda b: subprocess.Popen(["kitty", "--title", "SSH: nixos-rpi4", "-e", "ssh", "justkowal@192.168.1.22"]))
        self.row_rpi4.add_suffix(btn_ssh_rpi)
        nodes_group.add(self.row_rpi4)

        # Node 3: ThinkPad Laptop
        self.row_laptop = Adw.ActionRow(
            title="󰌢 thinkpad-laptop (ThinkPad T14s AMD)",
            subtitle="192.168.1.20 · Mobile Client · Tailscale Mesh Active"
        )
        if self.is_laptop:
            lbl_laptop_stat = Gtk.Label(label="󰄲 Active Local Host")
            lbl_laptop_stat.add_css_class("apple-status-green")
            self.row_laptop.add_suffix(lbl_laptop_stat)
        else:
            self.lbl_lap_stat = Gtk.Label(label="Probing...")
            self.row_laptop.add_suffix(self.lbl_lap_stat)
            btn_ssh_lap = Gtk.Button(label="SSH Terminal")
            btn_ssh_lap.set_valign(Gtk.Align.CENTER)
            btn_ssh_lap.connect("clicked", lambda b: subprocess.Popen(["kitty", "--title", "SSH: thinkpad-laptop", "-e", "ssh", "justkowal@192.168.1.20"]))
            self.row_laptop.add_suffix(btn_ssh_lap)
        nodes_group.add(self.row_laptop)

        # ── Group 2: Core Homelab Services ──
        services_group = Adw.PreferencesGroup(
            title="Hosted Infrastructure Services",
            description="Web services running on the deployment"
        )
        pref_page.add(services_group)

        for name, url, desc in SERVICES:
            row = Adw.ActionRow(title=name, subtitle=f"{url} — {desc}")
            btn_open = Gtk.Button(label="Open Web")
            btn_open.set_valign(Gtk.Align.CENTER)
            btn_open.connect("clicked", lambda b, u=url: subprocess.Popen(["xdg-open", u]))
            row.add_suffix(btn_open)
            services_group.add(row)

        # ── Group 3: Device Interaction Tools ──
        tools_group = Adw.PreferencesGroup(
            title="Hardware & Streaming Utilities",
            description="Manage peripheral sharing, control center, and virtual displays"
        )
        pref_page.add(tools_group)

        # Control Center
        row_cc = Adw.ActionRow(
            title="󰕮 System Control Center",
            subtitle="Audio sliders, brightness, power modes, and network info"
        )
        btn_cc = Gtk.Button(label="Open Control Center")
        btn_cc.set_valign(Gtk.Align.CENTER)
        btn_cc.connect("clicked", lambda b: subprocess.Popen(["control-center-gui"]))
        row_cc.add_suffix(btn_cc)
        tools_group.add(row_cc)

        # Seamless Mouse
        row_mouse = Adw.ActionRow(
            title="󰍽 Seamless Mouse & Desk Layout Setup",
            subtitle="Configure physical screen arrangement and lan-mouse KVM daemon"
        )
        btn_mouse = Gtk.Button(label="Configure Mouse")
        btn_mouse.set_valign(Gtk.Align.CENTER)
        btn_mouse.connect("clicked", lambda b: subprocess.Popen(["lan-mouse-gui"]))
        row_mouse.add_suffix(btn_mouse)
        tools_group.add(row_mouse)

        # Tablet Studio
        row_tablet = Adw.ActionRow(
            title="󰹑 Tablet Display Streaming Studio",
            subtitle="Manage Sunshine streaming and virtual headless display resolutions"
        )
        btn_tablet = Gtk.Button(label="Configure Tablet")
        btn_tablet.set_valign(Gtk.Align.CENTER)
        btn_tablet.connect("clicked", lambda b: subprocess.Popen(["tablet-display-gui"]))
        row_tablet.add_suffix(btn_tablet)
        tools_group.add(row_tablet)

        self.run_fleet_probe()
        GLib.timeout_add_seconds(15, self.run_fleet_probe)

    def run_fleet_probe(self):
        GLib.idle_add(self._probe_thread)
        return True

    def _probe_thread(self):
        # Probe RPi4
        try:
            p1 = subprocess.run(["ping", "-c", "1", "-W", "1", "192.168.1.22"], capture_output=True, text=True)
            if p1.returncode == 0:
                avg = "OK"
                for line in p1.stdout.splitlines():
                    if "rtt" in line or "round-trip" in line:
                        avg = line.split("/")[4] + " ms"
                        break
                self.lbl_rpi_stat.set_markup(f"<span class='apple-status-green'>󰄲 Online ({avg})</span>")
            else:
                self.lbl_rpi_stat.set_markup("<span class='apple-status-red'>󰅙 Offline</span>")
        except Exception:
            self.lbl_rpi_stat.set_markup("<span class='apple-status-red'>󰅙 Offline</span>")

        # Probe Laptop (if not local)
        if not self.is_laptop:
            try:
                p2 = subprocess.run(["ping", "-c", "1", "-W", "1", "192.168.1.20"], capture_output=True, text=True)
                if p2.returncode == 0:
                    avg = "OK"
                    for line in p2.stdout.splitlines():
                        if "rtt" in line or "round-trip" in line:
                            avg = line.split("/")[4] + " ms"
                            break
                    self.lbl_lap_stat.set_markup(f"<span class='apple-status-green'>󰄲 Online ({avg})</span>")
                else:
                    self.lbl_lap_stat.set_markup("<span class='apple-status-red'>󰅙 Offline</span>")
            except Exception:
                self.lbl_lap_stat.set_markup("<span class='apple-status-red'>󰅙 Offline</span>")

        # Probe Desktop (if running on laptop)
        if self.is_laptop:
            try:
                p3 = subprocess.run(["ping", "-c", "1", "-W", "1", "192.168.1.127"], capture_output=True, text=True)
                if p3.returncode == 0:
                    avg = "OK"
                    for line in p3.stdout.splitlines():
                        if "rtt" in line or "round-trip" in line:
                            avg = line.split("/")[4] + " ms"
                            break
                    self.lbl_desk_stat.set_markup(f"<span class='apple-status-green'>󰄲 Online ({avg})</span>")
                else:
                    self.lbl_desk_stat.set_markup("<span class='apple-status-red'>󰅙 Offline</span>")
            except Exception:
                self.lbl_desk_stat.set_markup("<span class='apple-status-red'>󰅙 Offline</span>")

        toast = Adw.Toast.new("Fleet status probed")
        toast.set_timeout(2)
        self.toast_overlay.add_toast(toast)
        return False

if __name__ == "__main__":
    app = FleetManagerApp()
    sys.exit(app.run(sys.argv))
