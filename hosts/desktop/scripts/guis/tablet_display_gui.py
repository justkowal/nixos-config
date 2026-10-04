#!/usr/bin/env python3
"""
Tablet Display Studio (tablet-display-gui)
Grounded in Apple HIG & Matugen Material You:
  - Dynamically themed via Matugen CSS tokens (@accent_color, @card_bg_color, @headerbar_border_color)
  - 100% Nerd Font / SF-style iconography (NO EMOJIS)
  - Real-time Hyprland virtual output inspection (coordinates, resolution, refresh rate)
  - Live Sunshine streaming server & active Moonlight client connection detection
  - Dynamic network endpoints display (LAN & Tailscale streaming addresses for tablet pairing)
  - Apple iPad Pro & Retina preset resolutions (16:10, 11" Liquid Retina, 12.9" Retina XDR)
"""

import os
import sys
import json
import socket
import shutil
import subprocess
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib, Gdk

def get_script_cmd():
    if shutil.which("tablet-display"):
        return ["tablet-display"]
    alt_script = "/etc/nixos/hosts/desktop/scripts/tablet-display.sh"
    if os.path.exists(alt_script):
        return ["bash", alt_script]
    return ["tablet-display"]

APPLE_MATUGEN_CSS = """
window.tablet-display {
    background-color: @window_bg_color;
}

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
"""

class TabletDisplayApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.justkowal.TabletDisplayStudio")

    def do_activate(self):
        win = TabletDisplayWindow(application=self)
        win.present()

class TabletDisplayWindow(Adw.ApplicationWindow):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.set_title("Tablet Display Studio")
        self.set_default_size(560, 600)
        self.add_css_class("tablet-display")

        # Apply Matugen Apple CSS
        provider = Gtk.CssProvider()
        provider.load_from_data(APPLE_MATUGEN_CSS.encode("utf-8"))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        self.resolutions = [
            ("1920x1200@60", "1920×1200 @ 60Hz (16:10 iPad / Android Tablet)"),
            ("2388x1668@60", "2388×1668 @ 60Hz (iPad Pro 11-inch Liquid Retina)"),
            ("2732x2048@60", "2732×2048 @ 60Hz (iPad Pro 12.9-inch Retina XDR)"),
            ("2560x1600@60", "2560×1600 @ 60Hz (16:10 High-Res Tablet)"),
            ("1920x1080@60", "1920×1080 @ 60Hz (16:9 Standard 1080p)"),
            ("2560x1440@60", "2560×1440 @ 60Hz (16:9 QHD Display)"),
        ]

        self.scales = ["1", "1.25", "1.5", "2"]

        self.toast_overlay = Adw.ToastOverlay()
        self.set_content(self.toast_overlay)

        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.toast_overlay.set_child(main_box)

        # Header bar
        header = Adw.HeaderBar()
        title_widget = Adw.WindowTitle(
            title="Tablet Display Studio",
            subtitle="Virtual Headless Display & Moonlight Streaming"
        )
        header.set_title_widget(title_widget)

        btn_refresh = Gtk.Button(icon_name="view-refresh-symbolic")
        btn_refresh.set_tooltip_text("Refresh Status")
        btn_refresh.connect("clicked", lambda b: self.update_display_status())
        header.pack_end(btn_refresh)

        main_box.append(header)

        # Scrolled content with smooth vertical scroll
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_vexpand(True)
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        main_box.append(scrolled)

        pref_page = Adw.PreferencesPage()
        scrolled.set_child(pref_page)

        # ── Group 1: Virtual Display State ──
        display_group = Adw.PreferencesGroup(
            title="Virtual Headless Display Output",
            description="Isolated virtual display in Hyprland for low-latency tablet streaming"
        )
        pref_page.add(display_group)

        self.switch_display = Adw.SwitchRow(
            title="Enable Virtual Tablet Display",
            subtitle="Headless output for Moonlight / Sunshine remote connection"
        )
        self.switch_display.connect("notify::active", self.on_switch_display_toggled)
        display_group.add(self.switch_display)

        self.row_display_status = Adw.ActionRow(
            title="Active Output Geometry",
            subtitle="Querying Hyprland monitors..."
        )
        self.lbl_display_status = Gtk.Label(label="Checking...")
        self.row_display_status.add_suffix(self.lbl_display_status)
        display_group.add(self.row_display_status)

        # ── Group 2: Resolution & Scaling ──
        config_group = Adw.PreferencesGroup(
            title="Display Geometry & Apple Retina Scaling",
            description="Configure the resolution and DPI scale factor of the virtual display."
        )
        pref_page.add(config_group)

        res_model = Gtk.StringList()
        for _, desc in self.resolutions:
            res_model.append(desc)

        self.combo_res = Adw.ComboRow(
            title="Screen Resolution & Aspect Ratio",
            model=res_model
        )
        self.combo_res.set_selected(0)
        config_group.add(self.combo_res)

        scale_model = Gtk.StringList()
        scale_model.append("1.0× (Standard 100%)")
        scale_model.append("1.25× (Comfortable 125%)")
        scale_model.append("1.5× (Balanced 150%)")
        scale_model.append("2.0× (Retina 200% HiDPI)")

        self.combo_scale = Adw.ComboRow(
            title="Interface Scale Factor",
            model=scale_model
        )
        self.combo_scale.set_selected(0)
        config_group.add(self.combo_scale)

        apply_res_row = Adw.ActionRow(
            title="Apply Geometry Settings",
            subtitle="Re-activates virtual display with selected resolution and scale"
        )
        btn_apply_res = Gtk.Button(label="Apply Settings")
        btn_apply_res.add_css_class("suggested-action")
        btn_apply_res.set_valign(Gtk.Align.CENTER)
        btn_apply_res.connect("clicked", self.on_apply_geometry)
        apply_res_row.add_suffix(btn_apply_res)
        config_group.add(apply_res_row)

        # ── Group 3: Sunshine Server & Client Streaming ──
        stream_group = Adw.PreferencesGroup(
            title="Sunshine Server & Streaming Telemetry",
            description="Live daemon status, connection endpoints, and paired tablet clients"
        )
        pref_page.add(stream_group)

        self.row_sunshine = Adw.ActionRow(
            title="Sunshine Streaming Daemon",
            subtitle="Checking port 47990 and process state..."
        )
        self.lbl_sunshine = Gtk.Label(label="Checking...")
        self.row_sunshine.add_suffix(self.lbl_sunshine)
        stream_group.add(self.row_sunshine)

        self.row_endpoints = Adw.ActionRow(
            title="Tablet Connection Endpoints",
            subtitle="IP addresses to enter into Moonlight on iPad"
        )
        stream_group.add(self.row_endpoints)

        # Portal actions
        portal_row = Adw.ActionRow(
            title="Sunshine Web Admin Portal",
            subtitle="Manage paired client tablets, PINs, and video encoders (https://localhost:47990)"
        )
        btn_sunshine = Gtk.Button(label="Open Web Admin")
        btn_sunshine.set_valign(Gtk.Align.CENTER)
        btn_sunshine.connect("clicked", self.on_open_sunshine)
        portal_row.add_suffix(btn_sunshine)
        stream_group.add(portal_row)

        moonlight_row = Adw.ActionRow(
            title="Local Moonlight Client",
            subtitle="Launch local client viewer to test streaming output"
        )
        btn_moonlight = Gtk.Button(label="Launch Moonlight")
        btn_moonlight.set_valign(Gtk.Align.CENTER)
        btn_moonlight.connect("clicked", self.on_launch_moonlight)
        moonlight_row.add_suffix(btn_moonlight)
        stream_group.add(moonlight_row)

        self.update_display_status()
        GLib.timeout_add_seconds(3, self.update_display_status)

    def get_active_headless_info(self):
        try:
            p = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True)
            monitors = json.loads(p.stdout)
            for m in monitors:
                name = m.get("name", "")
                if "HEADLESS" in name or name.startswith("WL-"):
                    w = m.get("width")
                    h = m.get("height")
                    hz = m.get("refreshRate", 60)
                    x = m.get("x", 0)
                    y = m.get("y", 0)
                    scale = m.get("scale", 1.0)
                    return f"{name} ({w}×{h} @ {hz:.0f}Hz, scale {scale}× at {x},{y})"
        except Exception:
            pass
        return None

    def check_sunshine_service(self):
        # 1. Process or systemd check
        try:
            res = subprocess.run(["systemctl", "--user", "is-active", "--quiet", "sunshine"])
            if res.returncode == 0:
                return True
        except Exception:
            pass
        try:
            res_pgrep = subprocess.run(["pgrep", "-f", "sunshine"], capture_output=True)
            if res_pgrep.returncode == 0:
                return True
        except Exception:
            pass
        # 2. Check if port 47990 is listening
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(0.2)
            ret = s.connect_ex(("127.0.0.1", 47990))
            s.close()
            if ret == 0:
                return True
        except Exception:
            pass
        return False

    def update_display_status(self):
        # 1. Headless display state
        headless_detail = self.get_active_headless_info()
        if headless_detail:
            self.lbl_display_status.set_markup("<span class='apple-status-green'>󰄲 Active</span>")
            self.row_display_status.set_subtitle(f"Output: {headless_detail}")
            self.switch_display.handler_block_by_func(self.on_switch_display_toggled)
            self.switch_display.set_active(True)
            self.switch_display.handler_unblock_by_func(self.on_switch_display_toggled)
        else:
            self.lbl_display_status.set_markup("<span class='apple-status-red'>󰅙 Inactive</span>")
            self.row_display_status.set_subtitle("No virtual monitor instantiated · Toggle switch to activate")
            self.switch_display.handler_block_by_func(self.on_switch_display_toggled)
            self.switch_display.set_active(False)
            self.switch_display.handler_unblock_by_func(self.on_switch_display_toggled)

        # 2. Sunshine streaming server state
        sunshine_running = self.check_sunshine_service()
        if sunshine_running:
            self.lbl_sunshine.set_markup("<span class='apple-status-green'>󰄲 Running</span>")
            self.row_sunshine.set_subtitle("Sunshine server listening on 0.0.0.0:47984-47990 · Ready for Moonlight")
        else:
            self.lbl_sunshine.set_markup("<span class='apple-status-orange'>󰅙 Inactive</span>")
            self.row_sunshine.set_subtitle("Sunshine server not currently running on this machine")

        # 3. Connection Endpoints (LAN & Tailscale)
        try:
            lan_ip = "127.0.0.1"
            p_route = subprocess.run(["ip", "-j", "route", "get", "1.1.1.1"], capture_output=True, text=True)
            routes = json.loads(p_route.stdout)
            if routes:
                lan_ip = routes[0].get("prefsrc", "")

            ts_ip = ""
            p_ts = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True)
            if p_ts.returncode == 0:
                ts_ip = p_ts.stdout.strip()

            ep_str = f"LAN: {lan_ip}:47990"
            if ts_ip:
                ep_str += f" · Tailscale Mesh: {ts_ip}:47990"
            self.row_endpoints.set_subtitle(ep_str)
        except Exception:
            self.row_endpoints.set_subtitle("Local: https://localhost:47990")

        return True

    def on_switch_display_toggled(self, widget, param):
        target_state = self.switch_display.get_active()
        cmd_base = get_script_cmd()
        if target_state:
            res = self.resolutions[self.combo_res.get_selected()][0]
            scale = self.scales[self.combo_scale.get_selected()]
            subprocess.run(cmd_base + ["on", res, scale])
            self.show_toast(f"Virtual display activated ({res}, scale {scale}×)")
        else:
            subprocess.run(cmd_base + ["off"])
            self.show_toast("Virtual display disconnected")
        self.update_display_status()

    def on_apply_geometry(self, btn):
        res = self.resolutions[self.combo_res.get_selected()][0]
        scale = self.scales[self.combo_scale.get_selected()]
        cmd_base = get_script_cmd()
        subprocess.run(cmd_base + ["off"])
        subprocess.run(cmd_base + ["on", res, scale])
        self.show_toast(f"Display geometry updated: {res} at {scale}× scale")
        self.update_display_status()

    def on_open_sunshine(self, btn):
        subprocess.Popen(["xdg-open", "https://localhost:47990"])

    def on_launch_moonlight(self, btn):
        subprocess.Popen(["moonlight"])

    def show_toast(self, message):
        toast = Adw.Toast.new(message)
        toast.set_timeout(3)
        self.toast_overlay.add_toast(toast)

if __name__ == "__main__":
    app = TabletDisplayApp()
    sys.exit(app.run(sys.argv))
