#!/usr/bin/env python3
"""
Apple-style System Control Center (control-center-gui)
Grounded in Apple HIG & Matugen Material You:
  - Dynamically styled with Matugen color tokens (@accent_color, @card_bg_color, @window_bg_color)
  - 100% Nerd Font / SF-style iconography (NO EMOJIS)
  - Live system telemetry: active audio sink name, microphone mute toggle, display model & geometry
  - Live hardware metrics: RAM utilization, CPU loadavg, battery wattage & charge threshold, uptime
  - Real-time network telemetry: interface name, gateway, local IP, Tailscale mesh status & peer count
  - Compact responsive layout (540x600) engineered for Laptop 1080p viewport and Desktop
"""

import os
import sys
import json
import socket
import subprocess
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib, Gdk

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
        self.set_default_size(540, 600)
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
        self.is_laptop = "laptop" in self.hostname or "thinkpad" in self.hostname or "t14s" in self.hostname

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

        # Scrolled content with smooth vertical scroll
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_vexpand(True)
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        main_box.append(scrolled)

        pref_page = Adw.PreferencesPage()
        scrolled.set_child(pref_page)

        # ── Group 1: Sound & Audio Devices ──
        audio_group = Adw.PreferencesGroup(title="Sound & Devices")
        pref_page.add(audio_group)

        # Output Volume
        self.row_volume = Adw.ActionRow(
            title="Output Volume",
            subtitle="Detecting PipeWire sink..."
        )
        vol_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        vol_box.set_valign(Gtk.Align.CENTER)

        self.lbl_volume = Gtk.Label(label="50%")
        self.lbl_volume.set_size_request(40, -1)
        vol_box.append(self.lbl_volume)

        self.scale_volume = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 150, 1)
        self.scale_volume.set_size_request(150, -1)
        self.scale_volume.connect("value-changed", self.on_volume_changed)
        vol_box.append(self.scale_volume)

        self.btn_mute = Gtk.Button(icon_name="audio-volume-high-symbolic")
        self.btn_mute.set_valign(Gtk.Align.CENTER)
        self.btn_mute.connect("clicked", self.on_mute_toggle)
        vol_box.append(self.btn_mute)

        self.row_volume.add_suffix(vol_box)
        audio_group.add(self.row_volume)

        # Input Mic
        self.row_mic = Adw.ActionRow(
            title="Microphone Input",
            subtitle="Detecting microphone source..."
        )
        mic_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        mic_box.set_valign(Gtk.Align.CENTER)

        self.lbl_mic = Gtk.Label(label="100%")
        self.lbl_mic.set_size_request(40, -1)
        mic_box.append(self.lbl_mic)

        self.btn_mic_mute = Gtk.Button(icon_name="audio-input-microphone-symbolic")
        self.btn_mic_mute.set_valign(Gtk.Align.CENTER)
        self.btn_mic_mute.connect("clicked", self.on_mic_mute_toggle)
        mic_box.append(self.btn_mic_mute)

        self.row_mic.add_suffix(mic_box)
        audio_group.add(self.row_mic)

        # ── Group 2: Display & Backlight ──
        display_group = Adw.PreferencesGroup(title="Display & Screen Geometry")
        pref_page.add(display_group)

        self.row_bright = Adw.ActionRow(
            title="Display Brightness",
            subtitle="Detecting active display output..."
        )
        bright_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        bright_box.set_valign(Gtk.Align.CENTER)

        self.lbl_bright = Gtk.Label(label="100%")
        self.lbl_bright.set_size_request(40, -1)
        bright_box.append(self.lbl_bright)

        self.scale_bright = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 5, 100, 1)
        self.scale_bright.set_size_request(150, -1)
        self.scale_bright.connect("value-changed", self.on_brightness_changed)
        bright_box.append(self.scale_bright)

        self.row_bright.add_suffix(bright_box)
        display_group.add(self.row_bright)

        # ── Group 3: Hardware Health & Performance ──
        power_group = Adw.PreferencesGroup(title="System Resources & Power")
        pref_page.add(power_group)

        self.row_battery = Adw.ActionRow(
            title="Power Supply & Battery",
            subtitle="Detecting power source..."
        )
        self.lbl_battery = Gtk.Label(label="Checking...")
        self.lbl_battery.add_css_class("apple-status-green")
        self.row_battery.add_suffix(self.lbl_battery)
        power_group.add(self.row_battery)

        self.row_perf = Adw.ActionRow(
            title="CPU Load & System RAM",
            subtitle="Reading /proc telemetry..."
        )
        self.lbl_perf_ram = Gtk.Label(label="RAM: ...")
        self.lbl_perf_ram.add_css_class("apple-status-accent")
        self.row_perf.add_suffix(self.lbl_perf_ram)
        power_group.add(self.row_perf)

        self.row_power_mode = Adw.ActionRow(
            title="CPU Power Profile",
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
        net_group = Adw.PreferencesGroup(title="Network Connectivity & Tailnet")
        pref_page.add(net_group)

        self.row_tailscale = Adw.ActionRow(
            title="󰖟 Tailscale Mesh VPN",
            subtitle="Encrypted peer-to-peer WireGuard mesh"
        )
        self.lbl_tailscale = Gtk.Label(label="Checking...")
        self.row_tailscale.add_suffix(self.lbl_tailscale)
        net_group.add(self.row_tailscale)

        self.row_local_ip = Adw.ActionRow(
            title="󰈀 Local Network Adapter",
            subtitle="Primary interface & gateway"
        )
        self.lbl_local_ip = Gtk.Label(label="Checking...")
        self.row_local_ip.add_suffix(self.lbl_local_ip)
        net_group.add(self.row_local_ip)

        # ── Group 5: Hardware & Fleet Companion Tools ──
        utils_group = Adw.PreferencesGroup(title="Hardware & Fleet Utilities")
        pref_page.add(utils_group)

        # 1. Fleet Manager
        row_fleet = Adw.ActionRow(
            title="󰒋 Deployment Fleet Center",
            subtitle="Dynamic multi-node status, SSH access, and hosted services"
        )
        btn_fleet = Gtk.Button(label="Open Fleet")
        btn_fleet.set_valign(Gtk.Align.CENTER)
        btn_fleet.connect("clicked", lambda b: subprocess.Popen(["fleet-manager-gui"]))
        row_fleet.add_suffix(btn_fleet)
        utils_group.add(row_fleet)

        # 2. Seamless Mouse
        row_mouse = Adw.ActionRow(
            title="󰍽 Seamless Mouse & Desk Layout",
            subtitle="Cross-machine KVM sharing & visual display arrangement"
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

        # ── Group 6: System Session Controls & Uptime ──
        session_group = Adw.PreferencesGroup(title="System Session & Diagnostics")
        pref_page.add(session_group)

        self.row_uptime = Adw.ActionRow(
            title="System Diagnostics",
            subtitle="Calculating uptime..."
        )
        session_group.add(self.row_uptime)

        session_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        session_box.set_halign(Gtk.Align.CENTER)
        session_box.set_margin_top(6)
        session_box.set_margin_bottom(10)

        btn_lock = Gtk.Button(label="󰌾 Lock")
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
        GLib.timeout_add_seconds(5, self.refresh_all)

    def refresh_all(self):
        self.update_volume_ui()
        self.update_brightness_ui()
        self.update_power_ui()
        self.update_network_ui()
        self.update_system_diagnostics()
        return True

    def update_volume_ui(self):
        # 1. Output Volume & Active Sink Description
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

            # Inspect sink device name
            sink_desc = "PipeWire Default Sink"
            inspect_proc = subprocess.run(["wpctl", "inspect", "@DEFAULT_AUDIO_SINK@"], capture_output=True, text=True)
            for line in inspect_proc.stdout.splitlines():
                if "node.description" in line:
                    sink_desc = line.split("=")[1].strip().strip('"')
                    break
            self.row_volume.set_subtitle(f"Active Sink: {sink_desc}")
        except Exception:
            pass

        # 2. Microphone Input Source
        try:
            mic_res = subprocess.run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@"], capture_output=True, text=True)
            mic_out = mic_res.stdout.strip()
            mic_parts = mic_out.split()
            if len(mic_parts) >= 2:
                m_vol = float(mic_parts[1])
                m_pct = int(m_vol * 100)
                m_muted = "[MUTED]" in mic_out
                self.lbl_mic.set_text(f"{m_pct}%")
                if m_muted:
                    self.btn_mic_mute.set_icon_name("microphone-disabled-symbolic")
                else:
                    self.btn_mic_mute.set_icon_name("audio-input-microphone-symbolic")

            mic_desc = "PipeWire Default Mic"
            inspect_mic = subprocess.run(["wpctl", "inspect", "@DEFAULT_AUDIO_SOURCE@"], capture_output=True, text=True)
            for line in inspect_mic.stdout.splitlines():
                if "node.description" in line:
                    mic_desc = line.split("=")[1].strip().strip('"')
                    break
            self.row_mic.set_subtitle(f"Active Input: {mic_desc}")
        except Exception:
            pass

    def on_volume_changed(self, scale):
        pct = int(scale.get_value())
        self.lbl_volume.set_text(f"{pct}%")
        subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f"{pct}%"])

    def on_mute_toggle(self, btn):
        subprocess.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
        self.update_volume_ui()
        self.show_toast("Audio output mute toggled")

    def on_mic_mute_toggle(self, btn):
        subprocess.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"])
        self.update_volume_ui()
        self.show_toast("Microphone mute toggled")

    def update_brightness_ui(self):
        # 1. Backlight slider
        try:
            backlight_dir = "/sys/class/backlight"
            if os.path.exists(backlight_dir) and os.listdir(backlight_dir):
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

        # 2. Active Monitor Details from Hyprland
        try:
            proc = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True)
            monitors = json.loads(proc.stdout)
            if monitors:
                m = monitors[0]
                m_name = m.get("name", "Screen")
                w = m.get("width")
                h = m.get("height")
                hz = m.get("refreshRate", 60)
                model = m.get("model", "")
                detail = f"{m_name} · {w}×{h} @ {hz:.0f}Hz"
                if model:
                    detail += f" ({model})"
                self.row_bright.set_subtitle(detail)
            else:
                self.row_bright.set_subtitle("Internal / External Display")
        except Exception:
            self.row_bright.set_subtitle("Primary Display")

    def on_brightness_changed(self, scale):
        pct = int(scale.get_value())
        self.lbl_bright.set_text(f"{pct}%")
        backlight_dir = "/sys/class/backlight"
        if os.path.exists(backlight_dir) and os.listdir(backlight_dir):
            subprocess.run(["brightnessctl", "set", f"{pct}%", "-q"])
        else:
            try:
                subprocess.run(["brightness-osd", "up"])
            except Exception:
                pass

    def update_power_ui(self):
        # 1. Battery check (ThinkPad BAT0 / BAT1)
        bat_dir = "/sys/class/power_supply/BAT0"
        if not os.path.exists(bat_dir):
            bat_dir = "/sys/class/power_supply/BAT1"

        if os.path.exists(bat_dir):
            try:
                cap = open(f"{bat_dir}/capacity").read().strip()
                status = open(f"{bat_dir}/status").read().strip()
                icon = "󰂄" if status == "Charging" else ("󰁹" if int(cap) > 20 else "󰂃")

                wattage_str = ""
                power_file = f"{bat_dir}/power_now"
                current_file = f"{bat_dir}/current_now"
                voltage_file = f"{bat_dir}/voltage_now"

                if os.path.exists(power_file):
                    power_uw = int(open(power_file).read().strip())
                    watts = power_uw / 1_000_000
                    wattage_str = f" · {watts:.1f}W"
                elif os.path.exists(current_file) and os.path.exists(voltage_file):
                    cur_ua = int(open(current_file).read().strip())
                    vol_uv = int(open(voltage_file).read().strip())
                    watts = (cur_ua * vol_uv) / 1_000_000_000_000
                    wattage_str = f" · {watts:.1f}W"

                thresh_file = f"{bat_dir}/charge_control_limit_max"
                if not os.path.exists(thresh_file):
                    thresh_file = f"{bat_dir}/charge_stop_threshold"
                thresh_str = ""
                if os.path.exists(thresh_file):
                    thresh = open(thresh_file).read().strip()
                    if thresh and thresh != "100":
                        thresh_str = f" [Limit: {thresh}%]"

                self.lbl_battery.set_text(f"{icon} {cap}% ({status}{wattage_str}){thresh_str}")
                self.row_battery.set_subtitle("ThinkPad Internal Battery (TLP Conservation Active)")
                self.row_battery.set_visible(True)
            except Exception:
                self.row_battery.set_visible(False)
        else:
            self.lbl_battery.set_text("󰚥 AC Mains")
            self.row_battery.set_subtitle("Desktop Workstation (Continuous AC Power)")
            self.row_battery.set_visible(True)

        # 2. CPU Load & RAM usage from /proc
        try:
            load = open("/proc/loadavg").read().split()[:3]
            load_fmt = f"Load: {' · '.join(load)}"

            with open("/proc/meminfo") as f:
                mem = {}
                for line in f:
                    p = line.split(":")
                    if len(p) == 2:
                        mem[p[0].strip()] = int(p[1].split()[0])
                total_gib = mem["MemTotal"] / (1024 * 1024)
                avail_gib = mem["MemAvailable"] / (1024 * 1024)
                used_gib = total_gib - avail_gib
                pct = int((used_gib / total_gib) * 100)

            self.lbl_perf_ram.set_text(f"RAM: {pct}% ({used_gib:.1f}/{total_gib:.1f} GiB)")
            self.row_perf.set_subtitle(f"{load_fmt} · Memory: {used_gib:.1f} GiB utilized")
        except Exception:
            pass

        # 3. Power Profile
        try:
            res = subprocess.run(["systemctl", "is-active", "--quiet", "ultra-power-save-runtime.service"])
            is_ultra = (res.returncode == 0)
            if is_ultra:
                self.lbl_power_mode.set_markup("<span class='apple-status-green'>󰌪 Ultra Low Power Active</span>")
            else:
                self.lbl_power_mode.set_markup("<span class='apple-status-accent'>󰓅 Standard / Performance</span>")
        except Exception:
            self.lbl_power_mode.set_text("Standard")

    def on_toggle_power_mode(self, btn):
        try:
            subprocess.run(["power-mode", "toggle"])
            self.show_toast("Power mode toggled")
            self.update_power_ui()
        except Exception:
            self.show_toast("Failed to toggle power mode")

    def update_network_ui(self):
        # 1. Tailscale Mesh
        try:
            p = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True)
            if p.returncode == 0:
                ts = json.loads(p.stdout)
                self_ips = ts.get("Self", {}).get("TailscaleIPs", [])
                ts_ip = self_ips[0] if self_ips else ""
                peers = ts.get("Peer", {})
                online_peers = sum(1 for _, peer in peers.items() if peer.get("Online", False))
                total_peers = len(peers)
                self.lbl_tailscale.set_markup(f"<span class='apple-status-green'>󰄲 Connected ({ts_ip})</span>")
                self.row_tailscale.set_subtitle(f"Tailnet: {ts.get('MagicDNSSuffix', 'mesh')} · {online_peers}/{total_peers} peers online")
            else:
                self.lbl_tailscale.set_markup("<span class='apple-status-orange'>󰅙 Mesh Inactive</span>")
        except Exception:
            self.lbl_tailscale.set_markup("<span class='apple-status-orange'>󰅙 Unavailable</span>")

        # 2. Local Network (Interface + Gateway)
        try:
            p_route = subprocess.run(["ip", "-j", "route", "get", "1.1.1.1"], capture_output=True, text=True)
            routes = json.loads(p_route.stdout)
            if routes:
                r = routes[0]
                dev = r.get("dev", "net")
                gw = r.get("gateway", "gateway")
                src_ip = r.get("prefsrc", "")
                self.lbl_local_ip.set_markup(f"<span class='apple-status-accent'>{src_ip}</span>")
                self.row_local_ip.set_subtitle(f"Interface: {dev} · Gateway: {gw}")
            else:
                self.lbl_local_ip.set_text("Disconnected")
        except Exception:
            self.lbl_local_ip.set_text("Active")

    def update_system_diagnostics(self):
        try:
            up_secs = int(float(open("/proc/uptime").read().split()[0]))
            h, rem = divmod(up_secs, 3600)
            d, h = divmod(h, 24)
            m, _ = divmod(rem, 60)
            uptime_str = f"{d}d {h}h {m}m" if d > 0 else f"{h}h {m}m"

            kernel = os.uname().release
            self.row_uptime.set_subtitle(f"Uptime: {uptime_str} · Kernel: Linux {kernel} · NixOS 26.05")
        except Exception:
            pass

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
