#!/usr/bin/env python3
"""
Apple-style System Control Center (control-center-gui)
Grounded in Apple HIG & Matugen Material You integration:
  - Dynamically styled with Matugen color tokens (@accent_color, @card_bg_color, @window_bg_color)
  - 100% Nerd Font / SF-style iconography (NO EMOJIS)
  - Clean modular cards with continuous curvature
  - High contrast typography (Outfit / SF Pro style)
  - Responsive hit targets >= 32px height
  - In-app toast feedback for all actions
"""

import os
import sys
import socket
import subprocess
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib, Gdk

# Apple HIG styling mapped directly to Matugen dynamic color tokens
APPLE_MATUGEN_CSS = """
window.control-center {
    background-color: @window_bg_color;
}

.apple-card {
    background-color: alpha(@card_bg_color, 0.45);
    border: 1px solid alpha(@headerbar_border_color, 0.25);
    border-radius: 14px;
    padding: 12px;
}

.apple-pill-btn {
    border-radius: 20px;
    padding: 6px 14px;
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

scale trough {
    border-radius: 8px;
    min-height: 8px;
    background-color: alpha(@card_bg_color, 0.65);
}

scale highlight {
    background: @accent_color;
    border-radius: 8px;
}
"""

class ControlCenterApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.justkowal.ControlCenter")

    def do_activate(self):
        win = ControlCenterWindow(application=self)
        win.present()

class ControlCenterWindow(Adw.ApplicationWindow):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.set_title("Control Center")
        self.set_default_size(580, 720)
        self.add_css_class("control-center")

        # Load Matugen-integrated Apple CSS Provider
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

        # Header Bar
        header = Adw.HeaderBar()
        title_widget = Adw.WindowTitle(
            title="Control Center",
            subtitle=f"{self.hostname} · System Quick Controls"
        )
        header.set_title_widget(title_widget)

        btn_refresh = Gtk.Button(icon_name="view-refresh-symbolic")
        btn_refresh.set_tooltip_text("Refresh All Statuses")
        btn_refresh.connect("clicked", lambda b: self.refresh_all())
        header.pack_end(btn_refresh)
        main_box.append(header)

        # Scrolled content
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_vexpand(True)
        main_box.append(scrolled)

        pref_page = Adw.PreferencesPage()
        scrolled.set_child(pref_page)

        # ── Group 1: Sound & Audio ──
        audio_group = Adw.PreferencesGroup(title="Sound")
        pref_page.add(audio_group)

        self.row_volume = Adw.ActionRow(
            title="Output Volume",
            subtitle="Default PipeWire Audio Sink"
        )
        vol_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        vol_box.set_valign(Gtk.Align.CENTER)

        self.lbl_volume = Gtk.Label(label="50%")
        self.lbl_volume.set_size_request(44, -1)
        vol_box.append(self.lbl_volume)

        self.scale_volume = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 150, 1)
        self.scale_volume.set_size_request(180, -1)
        self.scale_volume.connect("value-changed", self.on_volume_changed)
        vol_box.append(self.scale_volume)

        self.btn_mute = Gtk.Button(icon_name="audio-volume-high-symbolic")
        self.btn_mute.set_valign(Gtk.Align.CENTER)
        self.btn_mute.connect("clicked", self.on_mute_toggle)
        vol_box.append(self.btn_mute)

        self.row_volume.add_suffix(vol_box)
        audio_group.add(self.row_volume)

        # ── Group 2: Display & Backlight ──
        display_group = Adw.PreferencesGroup(title="Display")
        pref_page.add(display_group)

        self.row_bright = Adw.ActionRow(
            title="Screen Brightness",
            subtitle="Internal Backlight & External DDC/CI"
        )
        bright_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        bright_box.set_valign(Gtk.Align.CENTER)

        self.lbl_bright = Gtk.Label(label="100%")
        self.lbl_bright.set_size_request(44, -1)
        bright_box.append(self.lbl_bright)

        self.scale_bright = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 5, 100, 1)
        self.scale_bright.set_size_request(180, -1)
        self.scale_bright.connect("value-changed", self.on_brightness_changed)
        bright_box.append(self.scale_bright)

        self.row_bright.add_suffix(bright_box)
        display_group.add(self.row_bright)

        # ── Group 3: Power & Battery ──
        power_group = Adw.PreferencesGroup(title="Power & Performance")
        pref_page.add(power_group)

        self.row_battery = Adw.ActionRow(
            title="Battery & Health",
            subtitle="Power status and active wattage draw"
        )
        self.lbl_battery = Gtk.Label(label="Checking...")
        self.lbl_battery.add_css_class("apple-status-green")
        self.row_battery.add_suffix(self.lbl_battery)
        power_group.add(self.row_battery)

        self.row_power_mode = Adw.ActionRow(
            title="Power Profile",
            subtitle="Toggle CPU governor and ultra power saving mode"
        )
        self.lbl_power_mode = Gtk.Label(label="Checking...")
        self.row_power_mode.add_suffix(self.lbl_power_mode)

        btn_toggle_power = Gtk.Button(label="Toggle Profile")
        btn_toggle_power.set_valign(Gtk.Align.CENTER)
        btn_toggle_power.connect("clicked", self.on_toggle_power_mode)
        self.row_power_mode.add_suffix(btn_toggle_power)
        power_group.add(self.row_power_mode)

        # ── Group 4: Network & Tailscale Mesh ──
        net_group = Adw.PreferencesGroup(title="Network & Tailnet")
        pref_page.add(net_group)

        self.row_tailscale = Adw.ActionRow(
            title="󰖟 Tailscale Mesh VPN",
            subtitle="Encrypted multi-node peer mesh"
        )
        self.lbl_tailscale = Gtk.Label(label="Checking...")
        self.row_tailscale.add_suffix(self.lbl_tailscale)
        net_group.add(self.row_tailscale)

        self.row_local_ip = Adw.ActionRow(
            title="󰈀 Local LAN Network",
            subtitle="Primary network adapter & gateway"
        )
        self.lbl_local_ip = Gtk.Label(label="Checking...")
        self.row_local_ip.add_suffix(self.lbl_local_ip)
        net_group.add(self.row_local_ip)

        # ── Group 5: Custom GUIs & Utilities ──
        utils_group = Adw.PreferencesGroup(title="Hardware & Fleet Utilities")
        pref_page.add(utils_group)

        # 1. Fleet Manager
        row_fleet = Adw.ActionRow(
            title="󰒋 Deployment Fleet Center",
            subtitle="Multi-node NixOS status, SSH access, and hosted services"
        )
        btn_fleet = Gtk.Button(label="Open Fleet")
        btn_fleet.set_valign(Gtk.Align.CENTER)
        btn_fleet.connect("clicked", lambda b: subprocess.Popen(["fleet-manager-gui"]))
        row_fleet.add_suffix(btn_fleet)
        utils_group.add(row_fleet)

        # 2. Seamless Mouse
        row_mouse = Adw.ActionRow(
            title="󰍽 Seamless Mouse & Desk Layout",
            subtitle="Cross-machine mouse sharing (lan-mouse KVM) & display arrangement"
        )
        btn_mouse = Gtk.Button(label="Open Setup")
        btn_mouse.set_valign(Gtk.Align.CENTER)
        btn_mouse.connect("clicked", lambda b: subprocess.Popen(["lan-mouse-gui"]))
        row_mouse.add_suffix(btn_mouse)
        utils_group.add(row_mouse)

        # 3. Tablet Studio
        row_tablet = Adw.ActionRow(
            title="󰹑 Tablet Display Streaming Studio",
            subtitle="Headless virtual monitors and Sunshine/Moonlight remote streaming"
        )
        btn_tablet = Gtk.Button(label="Open Studio")
        btn_tablet.set_valign(Gtk.Align.CENTER)
        btn_tablet.connect("clicked", lambda b: subprocess.Popen(["tablet-display-gui"]))
        row_tablet.add_suffix(btn_tablet)
        utils_group.add(row_tablet)

        # ── Group 6: System Session Controls ──
        session_group = Adw.PreferencesGroup(title="Quick Session Actions")
        pref_page.add(session_group)

        session_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        session_box.set_halign(Gtk.Align.CENTER)
        session_box.set_margin_top(8)
        session_box.set_margin_bottom(12)

        btn_lock = Gtk.Button(label="󰌾 Lock Screen")
        btn_lock.connect("clicked", lambda b: subprocess.Popen(["loginctl", "lock-session"]))
        session_box.append(btn_lock)

        btn_suspend = Gtk.Button(label="󰒲 Sleep")
        btn_suspend.connect("clicked", self.on_suspend)
        session_box.append(btn_suspend)

        btn_reboot = Gtk.Button(label="󰑓 Reboot")
        btn_reboot.connect("clicked", lambda b: subprocess.Popen(["systemctl", "reboot"]))
        session_box.append(btn_reboot)

        btn_poweroff = Gtk.Button(label="󰐥 Shut Down")
        btn_poweroff.add_css_class("destructive-action")
        btn_poweroff.connect("clicked", lambda b: subprocess.Popen(["systemctl", "poweroff"]))
        session_box.append(btn_poweroff)

        session_group.add(session_box)

        # Initial refresh and recurring timer
        self.refresh_all()
        GLib.timeout_add_seconds(6, self.refresh_all)

    def refresh_all(self):
        self.update_volume_ui()
        self.update_brightness_ui()
        self.update_power_ui()
        self.update_network_ui()
        return True

    def update_volume_ui(self):
        try:
            res = subprocess.run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"], capture_output=True, text=True)
            output = res.stdout.strip()
            parts = output.split()
            if len(parts) >= 2:
                vol = float(parts[1])
                pct = int(vol * 100)
                is_muted = "[MUTED]" in output
                self.lbl_volume.set_text(f"{pct}%")
                self.scale_volume.handler_block_by_func(self.on_volume_changed)
                self.scale_volume.set_value(pct)
                self.scale_volume.handler_unblock_by_func(self.on_volume_changed)
                if is_muted:
                    self.btn_mute.set_icon_name("audio-volume-muted-symbolic")
                else:
                    self.btn_mute.set_icon_name("audio-volume-high-symbolic")
        except Exception:
            pass

    def on_volume_changed(self, scale):
        pct = int(scale.get_value())
        self.lbl_volume.set_text(f"{pct}%")
        subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f"{pct}%"])

    def on_mute_toggle(self, btn):
        subprocess.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
        self.update_volume_ui()
        self.show_toast("Audio mute toggled")

    def update_brightness_ui(self):
        try:
            if os.path.exists("/sys/class/backlight") and os.listdir("/sys/class/backlight"):
                cur = int(subprocess.run(["brightnessctl", "g"], capture_output=True, text=True).stdout.strip())
                mx = int(subprocess.run(["brightnessctl", "m"], capture_output=True, text=True).stdout.strip())
                pct = int((cur / max(mx, 1)) * 100)
            else:
                pct = 100
            self.lbl_bright.set_text(f"{pct}%")
            self.scale_bright.handler_block_by_func(self.on_brightness_changed)
            self.scale_bright.set_value(pct)
            self.scale_bright.handler_unblock_by_func(self.on_brightness_changed)
        except Exception:
            pass

    def on_brightness_changed(self, scale):
        pct = int(scale.get_value())
        self.lbl_bright.set_text(f"{pct}%")
        if os.path.exists("/sys/class/backlight") and os.listdir("/sys/class/backlight"):
            subprocess.run(["brightnessctl", "s", f"{pct}%", "-q"])
        else:
            subprocess.run(["bash", "/etc/nixos/hosts/desktop/scripts/brightness-osd.sh", "up"])

    def update_power_ui(self):
        # Battery check
        bat_dir = "/sys/class/power_supply/BAT0"
        if os.path.exists(bat_dir):
            try:
                cap = open(f"{bat_dir}/capacity").read().strip()
                status = open(f"{bat_dir}/status").read().strip()
                icon = "󰂄" if status == "Charging" else "󰁹"
                self.lbl_battery.set_text(f"{icon} {cap}% ({status})")
                self.lbl_battery.set_visible(True)
                self.row_battery.set_visible(True)
            except Exception:
                self.row_battery.set_visible(False)
        else:
            self.row_battery.set_visible(False)

        # Power Mode check
        try:
            res = subprocess.run(["systemctl", "is-active", "--quiet", "ultra-power-save-runtime.service"])
            is_ultra = (res.returncode == 0)
            if is_ultra:
                self.lbl_power_mode.set_markup("<span class='apple-status-green'>󰌪 Ultra Low Power Active</span>")
            else:
                self.lbl_power_mode.set_markup("<span class='apple-status-accent'>󰓅 Standard / Performance</span>")
        except Exception:
            self.lbl_power_mode.set_text("Unknown")

    def on_toggle_power_mode(self, btn):
        try:
            subprocess.run(["power-mode", "toggle"])
            self.show_toast("Power mode toggled")
            self.update_power_ui()
        except Exception:
            self.show_toast("Failed to toggle power mode")

    def update_network_ui(self):
        # Tailscale
        try:
            res = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True)
            ts_ip = res.stdout.strip()
            if res.returncode == 0 and ts_ip:
                self.lbl_tailscale.set_markup(f"<span class='apple-status-green'>󰄲 Connected ({ts_ip})</span>")
            else:
                self.lbl_tailscale.set_markup("<span class='apple-status-orange'>󰅙 Mesh Inactive</span>")
        except Exception:
            self.lbl_tailscale.set_markup("<span class='apple-status-orange'>󰅙 Unavailable</span>")

        # Local IP
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("1.1.1.1", 53))
            local_ip = s.getsockname()[0]
            s.close()
            self.lbl_local_ip.set_markup(f"<span class='apple-status-accent'>{local_ip}</span>")
        except Exception:
            self.lbl_local_ip.set_text("Disconnected")

    def on_suspend(self, btn):
        subprocess.Popen(["loginctl", "lock-session"])
        subprocess.Popen(["systemctl", "suspend"])

    def show_toast(self, message):
        toast = Adw.Toast.new(message)
        toast.set_timeout(3)
        self.toast_overlay.add_toast(toast)

if __name__ == "__main__":
    app = ControlCenterApp()
    sys.exit(app.run(sys.argv))
