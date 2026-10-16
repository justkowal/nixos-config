#!/usr/bin/env python3
"""
Apple-style System Control Center (control-center-gui)
Grounded in Apple HIG & Matugen Material You:
  - Dynamically styled with Matugen color tokens (@accent_color, @card_bg_color, @window_bg_color)
  - 100% Nerd Font / SF-style iconography (NO EMOJIS)
  - Live system telemetry: active audio sink name, microphone mute toggle, display model & geometry
  - Live hardware metrics: RAM utilization, CPU loadavg, battery wattage & charge threshold, uptime
  - Real-time network telemetry: interface name, gateway, local IP, Tailscale mesh status & peer count
  - Universal brightness control: brightnessctl on laptop, DDC/CI ddcutil on desktop
  - Compact responsive layout (540x600) engineered for Laptop 1080p viewport and Desktop
"""

import os
import sys
import json
import socket
import shutil
import threading
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
        self.set_default_size(540, 620)
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
        btn_refresh.add_css_class("apple-pill-btn")
        btn_refresh.set_valign(Gtk.Align.CENTER)
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
        audio_group = Adw.PreferencesGroup(title="Sound and Audio Devices")
        pref_page.add(audio_group)

        # Output Volume
        self.row_volume = Adw.ActionRow(
            title="Output Volume",
            subtitle="Detecting PipeWire sink..."
        )
        self.row_volume.add_prefix(make_icon_prefix("󰕾"))
        vol_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        vol_box.set_valign(Gtk.Align.CENTER)

        self.lbl_volume = Gtk.Label(label="50%")
        self.lbl_volume.set_size_request(40, -1)
        self.lbl_volume.set_valign(Gtk.Align.CENTER)
        vol_box.append(self.lbl_volume)

        self.scale_volume = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 150, 1)
        self.scale_volume.set_size_request(140, -1)
        self.scale_volume.set_valign(Gtk.Align.CENTER)
        self.scale_volume.connect("value-changed", self.on_volume_changed)
        vol_box.append(self.scale_volume)

        self.btn_mute = Gtk.Button(icon_name="audio-volume-high-symbolic")
        self.btn_mute.set_valign(Gtk.Align.CENTER)
        self.btn_mute.add_css_class("apple-pill-btn")
        self.btn_mute.connect("clicked", self.on_mute_toggle)
        vol_box.append(self.btn_mute)

        self.row_volume.add_suffix(vol_box)
        audio_group.add(self.row_volume)

        # Input Mic
        self.row_mic = Adw.ActionRow(
            title="Microphone Input",
            subtitle="Detecting microphone source..."
        )
        self.row_mic.add_prefix(make_icon_prefix("󰍬"))
        mic_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        mic_box.set_valign(Gtk.Align.CENTER)

        self.lbl_mic = Gtk.Label(label="100%")
        self.lbl_mic.set_size_request(40, -1)
        self.lbl_mic.set_valign(Gtk.Align.CENTER)
        mic_box.append(self.lbl_mic)

        self.btn_mic_mute = Gtk.Button(icon_name="audio-input-microphone-symbolic")
        self.btn_mic_mute.set_valign(Gtk.Align.CENTER)
        self.btn_mic_mute.add_css_class("apple-pill-btn")
        self.btn_mic_mute.connect("clicked", self.on_mic_mute_toggle)
        mic_box.append(self.btn_mic_mute)

        self.row_mic.add_suffix(mic_box)
        audio_group.add(self.row_mic)

        # ── Group 2: Display & Backlight ──
        # one row per monitor, rebuilt in update_brightness_ui when screens come and go
        self.display_group = Adw.PreferencesGroup(title="Display and Screen Brightness")
        pref_page.add(self.display_group)
        self.bright_rows = {}

        # ── Group 3: Hardware Health & Performance ──
        power_group = Adw.PreferencesGroup(title="System Resources and Power")
        pref_page.add(power_group)

        self.row_battery = Adw.ActionRow(
            title="Power Supply and Battery",
            subtitle="Detecting power source..."
        )
        self.row_battery.add_prefix(make_icon_prefix("󰚥"))
        self.lbl_battery = Gtk.Label(label="Checking...")
        set_badge(self.lbl_battery, "Checking...", "apple-status-green")
        self.row_battery.add_suffix(self.lbl_battery)

        self.btn_bat_inspect = Gtk.Button(label="Inspect")
        self.btn_bat_inspect.add_css_class("apple-pill-btn")
        self.btn_bat_inspect.set_valign(Gtk.Align.CENTER)
        self.btn_bat_inspect.connect("clicked", self.on_open_battery_inspector)
        self.row_battery.add_suffix(self.btn_bat_inspect)
        self.row_battery.set_activatable(True)
        self.row_battery.connect("activated", self.on_open_battery_inspector)
        power_group.add(self.row_battery)

        self.row_perf = Adw.ActionRow(
            title="CPU Load and System RAM",
            subtitle="Reading /proc telemetry..."
        )
        self.row_perf.add_prefix(make_icon_prefix("󰍛"))
        self.lbl_perf_ram = Gtk.Label(label="RAM: ...")
        set_badge(self.lbl_perf_ram, "RAM: ...", "apple-status-accent")
        self.row_perf.add_suffix(self.lbl_perf_ram)
        power_group.add(self.row_perf)

        self.row_power_mode = Adw.ActionRow(
            title="CPU Power Profile",
            subtitle="Toggle CPU governor and ultra power saving mode"
        )
        self.row_power_mode.add_prefix(make_icon_prefix("󰓅"))
        self.lbl_power_mode = Gtk.Label(label="Checking...")
        set_badge(self.lbl_power_mode, "Checking...", "apple-status-accent")
        self.row_power_mode.add_suffix(self.lbl_power_mode)

        btn_toggle_power = Gtk.Button(label="Toggle Profile")
        btn_toggle_power.add_css_class("apple-pill-btn")
        btn_toggle_power.set_valign(Gtk.Align.CENTER)
        btn_toggle_power.connect("clicked", self.on_toggle_power_mode)
        self.row_power_mode.add_suffix(btn_toggle_power)
        power_group.add(self.row_power_mode)

        # Caffeine Mode (Inhibits sleep & lid-close suspend while preserving locking)
        self.row_caffeine = Adw.ActionRow(
            title="Caffeine Mode (Keep Awake)",
            subtitle="Inhibits sleep and lid-close suspend (locks on lid close)"
        )
        self.row_caffeine.add_prefix(make_icon_prefix("󰅶"))
        self.lbl_caffeine = Gtk.Label(label="Checking...")
        set_badge(self.lbl_caffeine, "Checking...", "apple-status-accent")
        self.row_caffeine.add_suffix(self.lbl_caffeine)

        btn_toggle_caffeine = Gtk.Button(label="Toggle")
        btn_toggle_caffeine.add_css_class("apple-pill-btn")
        btn_toggle_caffeine.set_valign(Gtk.Align.CENTER)
        btn_toggle_caffeine.connect("clicked", self.on_toggle_caffeine)
        self.row_caffeine.add_suffix(btn_toggle_caffeine)
        power_group.add(self.row_caffeine)

        # ── Group 4: Network & Tailscale Mesh ──
        net_group = Adw.PreferencesGroup(title="Network Connectivity and Mesh")
        pref_page.add(net_group)

        self.row_tailscale = Adw.ActionRow(
            title="Tailscale Mesh VPN",
            subtitle="Encrypted peer-to-peer WireGuard mesh"
        )
        self.row_tailscale.add_prefix(make_icon_prefix("󰒋"))
        self.lbl_tailscale = Gtk.Label(label="Checking...")
        set_badge(self.lbl_tailscale, "Checking...", "apple-status-orange")
        self.row_tailscale.add_suffix(self.lbl_tailscale)
        net_group.add(self.row_tailscale)

        self.row_local_ip = Adw.ActionRow(
            title="Local Network Adapter",
            subtitle="Primary interface and gateway"
        )
        self.row_local_ip.add_prefix(make_icon_prefix("󰈀"))
        self.lbl_local_ip = Gtk.Label(label="Checking...")
        set_badge(self.lbl_local_ip, "Checking...", "apple-status-accent")
        self.row_local_ip.add_suffix(self.lbl_local_ip)
        net_group.add(self.row_local_ip)

        # ── Group 5: Hardware & Fleet Companion Tools ──
        utils_group = Adw.PreferencesGroup(title="Fleet Companion Utilities")
        pref_page.add(utils_group)

        # 1. Fleet Manager
        row_fleet = Adw.ActionRow(
            title="Deployment Fleet Center",
            subtitle="Dynamic multi-node status, SSH access, and hosted services"
        )
        row_fleet.add_prefix(make_icon_prefix("󰒋"))
        btn_fleet = Gtk.Button(label="Open Fleet")
        btn_fleet.add_css_class("apple-pill-btn")
        btn_fleet.set_valign(Gtk.Align.CENTER)
        btn_fleet.connect("clicked", lambda b: subprocess.Popen(["fleet-manager-gui"]))
        row_fleet.add_suffix(btn_fleet)
        utils_group.add(row_fleet)

        # 2. Seamless Mouse
        row_mouse = Adw.ActionRow(
            title="Seamless Mouse and Desk Layout",
            subtitle="Cross-machine KVM sharing and visual display arrangement"
        )
        row_mouse.add_prefix(make_icon_prefix("󰍽"))
        btn_mouse = Gtk.Button(label="Open Setup")
        btn_mouse.add_css_class("apple-pill-btn")
        btn_mouse.set_valign(Gtk.Align.CENTER)
        btn_mouse.connect("clicked", lambda b: subprocess.Popen(["lan-mouse-gui"]))
        row_mouse.add_suffix(btn_mouse)
        utils_group.add(row_mouse)

        # 3. Tablet Studio
        row_tablet = Adw.ActionRow(
            title="Tablet Display Streaming Studio",
            subtitle="Headless virtual monitors and Sunshine/Moonlight remote streaming"
        )
        row_tablet.add_prefix(make_icon_prefix("󰹑"))
        btn_tablet = Gtk.Button(label="Open Studio")
        btn_tablet.add_css_class("apple-pill-btn")
        btn_tablet.set_valign(Gtk.Align.CENTER)
        btn_tablet.connect("clicked", lambda b: subprocess.Popen(["tablet-display-gui"]))
        row_tablet.add_suffix(btn_tablet)
        utils_group.add(row_tablet)

        # ── Group 6: System Session Controls & Uptime ──
        session_group = Adw.PreferencesGroup(title="System Diagnostics and Session")
        pref_page.add(session_group)

        self.row_uptime = Adw.ActionRow(
            title="System Diagnostics",
            subtitle="Calculating uptime..."
        )
        self.row_uptime.add_prefix(make_icon_prefix("󰋊"))
        session_group.add(self.row_uptime)

        session_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        session_box.set_halign(Gtk.Align.CENTER)
        session_box.set_margin_top(8)
        session_box.set_margin_bottom(12)

        btn_lock = Gtk.Button(label="󰌾  Lock")
        btn_lock.add_css_class("apple-pill-btn")
        btn_lock.connect("clicked", lambda b: subprocess.Popen(["loginctl", "lock-session"]))
        session_box.append(btn_lock)

        btn_suspend = Gtk.Button(label="󰒲  Sleep")
        btn_suspend.add_css_class("apple-pill-btn")
        btn_suspend.connect("clicked", self.on_suspend)
        session_box.append(btn_suspend)

        btn_reboot = Gtk.Button(label="󰑓  Reboot")
        btn_reboot.add_css_class("apple-pill-btn")
        btn_reboot.connect("clicked", lambda b: subprocess.Popen(["systemctl", "reboot"]))
        session_box.append(btn_reboot)

        btn_poweroff = Gtk.Button(label="󰐥  Shut Down")
        btn_poweroff.add_css_class("apple-pill-btn")
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
        try:
            proc = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True, timeout=2)
            monitors = [m for m in json.loads(proc.stdout) if not m.get("name", "").startswith("HEADLESS")]
        except Exception:
            monitors = []

        names = [m["name"] for m in monitors]
        if names != list(self.bright_rows):
            for entry in self.bright_rows.values():
                self.display_group.remove(entry["row"])
            self.bright_rows = {}
            for m in monitors:
                self._add_brightness_row(m)

        for m in monitors:
            entry = self.bright_rows[m["name"]]
            detail = f"{m['name']} · {m.get('width')}×{m.get('height')} @ {m.get('refreshRate', 60):.0f}Hz"
            if m.get("model"):
                detail += f" ({m['model']})"
            if m.get("focused") and len(monitors) > 1:
                detail += " · focused"
            entry["row"].set_subtitle(detail)

        # ddc reads take ~100ms per screen, keep them off the main loop
        def _read(names):
            for name in names:
                try:
                    p = subprocess.run(["brightness-osd", "get", name], capture_output=True, text=True, timeout=4)
                    GLib.idle_add(self._apply_brightness_value, name, int(p.stdout.strip()))
                except Exception:
                    pass
        idle = [n for n, e in self.bright_rows.items() if e["timer"] is None]
        threading.Thread(target=_read, args=(idle,), daemon=True).start()

    def _add_brightness_row(self, m):
        name = m["name"]
        row = Adw.ActionRow(title="Panel Brightness" if name.startswith("eDP") else "External Display")
        row.add_prefix(make_icon_prefix("󰃠" if name.startswith("eDP") else "󰍹"))
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        box.set_valign(Gtk.Align.CENTER)

        lbl = Gtk.Label(label="--")
        lbl.set_size_request(40, -1)
        lbl.set_valign(Gtk.Align.CENTER)
        box.append(lbl)

        scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 5, 100, 1)
        scale.set_size_request(140, -1)
        scale.set_valign(Gtk.Align.CENTER)
        scale.connect("value-changed", self.on_brightness_changed, name)
        box.append(scale)

        row.add_suffix(box)
        self.display_group.add(row)
        self.bright_rows[name] = {"row": row, "lbl": lbl, "scale": scale, "timer": None, "target": 100}

    def _apply_brightness_value(self, name: str, pct: int):
        entry = self.bright_rows.get(name)
        if not entry or entry["timer"] is not None:
            return False
        entry["lbl"].set_text(f"{pct}%")
        entry["scale"].handler_block_by_func(self.on_brightness_changed)
        entry["scale"].set_value(pct)
        entry["scale"].handler_unblock_by_func(self.on_brightness_changed)
        return False

    def on_brightness_changed(self, scale, name):
        entry = self.bright_rows[name]
        pct = int(scale.get_value())
        entry["lbl"].set_text(f"{pct}%")
        entry["target"] = pct

        # debounce: ddc/ci chokes on a write per slider tick
        if entry["timer"]:
            GLib.source_remove(entry["timer"])
        entry["timer"] = GLib.timeout_add(150, self._apply_hardware_brightness, name)

    def _apply_hardware_brightness(self, name):
        entry = self.bright_rows.get(name)
        if not entry:
            return False
        entry["timer"] = None
        threading.Thread(
            target=subprocess.run,
            args=(["brightness-osd", "set", str(entry["target"]), name],),
            kwargs={"capture_output": True},
            daemon=True,
        ).start()
        return False

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

                set_badge(self.lbl_battery, f"{icon} {cap}% ({status}{wattage_str}){thresh_str}", "apple-status-green")
                self.row_battery.set_subtitle("ThinkPad Internal Battery (Click to Inspect)")
                self.row_battery.set_visible(True)
                self.btn_bat_inspect.set_visible(True)
                self.row_battery.set_activatable(True)
            except Exception:
                self.row_battery.set_visible(False)
        else:
            set_badge(self.lbl_battery, "󰚥 AC Mains", "apple-status-green")
            self.row_battery.set_subtitle("Desktop Workstation (Continuous AC Power)")
            self.row_battery.set_visible(True)
            self.btn_bat_inspect.set_visible(False)
            self.row_battery.set_activatable(False)

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

            set_badge(self.lbl_perf_ram, f"RAM: {pct}% ({used_gib:.1f}/{total_gib:.1f} GiB)", "apple-status-accent")
            self.row_perf.set_subtitle(f"{load_fmt} · Memory: {used_gib:.1f} GiB utilized")
        except Exception:
            pass

        # 3. Power Profile
        try:
            res = subprocess.run(["power-mode", "status"], capture_output=True, text=True)
            if "ULTRA LOW POWER ACTIVE" in res.stdout:
                set_badge(self.lbl_power_mode, "󰌪 Ultra Low Power Active", "apple-status-green")
            else:
                set_badge(self.lbl_power_mode, "󰓅 Standard / Performance", "apple-status-accent")
        except Exception:
            set_badge(self.lbl_power_mode, "Standard", "apple-status-accent")

        # 4. Caffeine Mode
        self.update_caffeine_ui()

    def update_caffeine_ui(self):
        try:
            res = subprocess.run(["caffeine", "status"], capture_output=True, text=True)
            active = (res.stdout.strip() == "active")
            if active:
                set_badge(self.lbl_caffeine, "󰅶 Active (Inhibiting Sleep)", "apple-status-green")
            else:
                set_badge(self.lbl_caffeine, "󰒲 Inactive (Normal Sleep)", "apple-status-accent")
        except Exception:
            set_badge(self.lbl_caffeine, "Inactive", "apple-status-accent")

    def on_toggle_caffeine(self, btn):
        try:
            subprocess.run(["caffeine", "toggle"], capture_output=True)
            self.update_caffeine_ui()
        except Exception:
            pass

    def on_toggle_power_mode(self, btn):
        try:
            subprocess.run(["power-mode", "toggle"])
            self.update_power_ui()
        except Exception:
            pass

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
                set_badge(self.lbl_tailscale, f"󰄲 Connected ({ts_ip})", "apple-status-green")
                self.row_tailscale.set_subtitle(f"Tailnet: {ts.get('MagicDNSSuffix', 'mesh')} · {online_peers}/{total_peers} peers online")
            else:
                set_badge(self.lbl_tailscale, "󰅙 Mesh Inactive", "apple-status-orange")
        except Exception:
            set_badge(self.lbl_tailscale, "󰅙 Unavailable", "apple-status-orange")

        # 2. Local Network (Interface + Gateway)
        try:
            p_route = subprocess.run(["ip", "-j", "route", "get", "1.1.1.1"], capture_output=True, text=True)
            routes = json.loads(p_route.stdout)
            if routes:
                r = routes[0]
                dev = r.get("dev", "net")
                gw = r.get("gateway", "gateway")
                src_ip = r.get("prefsrc", "")
                set_badge(self.lbl_local_ip, src_ip, "apple-status-accent")
                self.row_local_ip.set_subtitle(f"Interface: {dev} · Gateway: {gw}")
            else:
                set_badge(self.lbl_local_ip, "Disconnected", "apple-status-red")
        except Exception:
            set_badge(self.lbl_local_ip, "Active", "apple-status-accent")

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

    def on_open_battery_inspector(self, *args):
        win = BatteryInspectorWindow(transient_for=self)
        win.present()

    def on_suspend(self, btn):
        subprocess.Popen(["loginctl", "lock-session"])
        subprocess.Popen(["systemctl", "suspend"])

    def show_toast(self, message):
        toast = Adw.Toast.new(message)
        toast.set_timeout(3)
        self.toast_overlay.add_toast(toast)

class BatteryInspectorWindow(Adw.Window):
    """
    Apple HIG Battery Health and Power Diagnostics Inspector.
    Displays maximum capacity %, cycle count, live charging wattage,
    charging limit profiles, and hardware architecture tips.
    """
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.set_title("Battery Health and Power")
        self.set_default_size(520, 660)
        self.set_modal(True)

        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_content(main_box)

        header = Adw.HeaderBar()
        title_widget = Adw.WindowTitle(
            title="Battery Health and Power",
            subtitle="ThinkPad Internal Battery Diagnostics"
        )
        header.set_title_widget(title_widget)

        btn_refresh = Gtk.Button(icon_name="view-refresh-symbolic")
        btn_refresh.set_tooltip_text("Refresh Battery Telemetry")
        btn_refresh.add_css_class("apple-pill-btn")
        btn_refresh.set_valign(Gtk.Align.CENTER)
        btn_refresh.connect("clicked", lambda b: self.refresh_data())
        header.pack_end(btn_refresh)
        main_box.append(header)

        scrolled = Gtk.ScrolledWindow()
        scrolled.set_vexpand(True)
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        main_box.append(scrolled)

        self.pref_page = Adw.PreferencesPage()
        scrolled.set_child(self.pref_page)

        # ── Group 1: Battery Health & Maximum Capacity ──
        grp_health = Adw.PreferencesGroup(title="Battery Health")
        self.pref_page.add(grp_health)

        self.row_health = Adw.ActionRow(
            title="Maximum Capacity",
            subtitle="A measure of battery capacity relative to when it was new."
        )
        self.row_health.add_prefix(make_icon_prefix("󰁹"))
        self.lbl_health_badge = Gtk.Label(label="Checking...")
        set_badge(self.lbl_health_badge, "Checking...", "apple-status-green")
        self.row_health.add_suffix(self.lbl_health_badge)
        grp_health.add(self.row_health)

        self.row_energy = Adw.ActionRow(
            title="Full Charge Capacity",
            subtitle="Current energy retention vs factory design capacity"
        )
        self.row_energy.add_prefix(make_icon_prefix("󰂄"))
        self.lbl_energy_badge = Gtk.Label(label="...")
        set_badge(self.lbl_energy_badge, "...", "apple-status-accent")
        self.row_energy.add_suffix(self.lbl_energy_badge)
        grp_health.add(self.row_energy)

        self.row_cycles = Adw.ActionRow(
            title="Cycle Count",
            subtitle="Total lifetime discharge cycles completed"
        )
        self.row_cycles.add_prefix(make_icon_prefix("󰑐"))
        self.lbl_cycles_badge = Gtk.Label(label="...")
        set_badge(self.lbl_cycles_badge, "...", "apple-status-accent")
        self.row_cycles.add_suffix(self.lbl_cycles_badge)
        grp_health.add(self.row_cycles)

        # ── Group 2: Live Power Flow & Speed ──
        grp_flow = Adw.PreferencesGroup(title="Real-Time Power Telemetry")
        self.pref_page.add(grp_flow)

        self.row_flow_level = Adw.ActionRow(
            title="Current Charge Level",
            subtitle="Real-time stored battery charge percentage"
        )
        self.row_flow_level.add_prefix(make_icon_prefix("󰚥"))
        self.lbl_flow_level = Gtk.Label(label="...")
        set_badge(self.lbl_flow_level, "...", "apple-status-green")
        self.row_flow_level.add_suffix(self.lbl_flow_level)
        grp_flow.add(self.row_flow_level)

        self.row_flow_speed = Adw.ActionRow(
            title="Power Flow / Charging Speed",
            subtitle="Instantaneous rate of electrical energy transfer"
        )
        self.row_flow_speed.add_prefix(make_icon_prefix("󱐋"))
        self.lbl_flow_speed = Gtk.Label(label="...")
        set_badge(self.lbl_flow_speed, "...", "apple-status-accent")
        self.row_flow_speed.add_suffix(self.lbl_flow_speed)
        grp_flow.add(self.row_flow_speed)

        self.row_flow_time = Adw.ActionRow(
            title="Estimated Time Remaining",
            subtitle="Duration to complete full target charge or discharge"
        )
        self.row_flow_time.add_prefix(make_icon_prefix("󰥔"))
        self.lbl_flow_time = Gtk.Label(label="...")
        set_badge(self.lbl_flow_time, "...", "apple-status-accent")
        self.row_flow_time.add_suffix(self.lbl_flow_time)
        grp_flow.add(self.row_flow_time)

        # ── Group 3: Charging Limit Profiles & Visuals ──
        grp_limits = Adw.PreferencesGroup(title="Charging Limit Profiles and Visuals")
        self.pref_page.add(grp_limits)

        row_conserve = Adw.ActionRow(
            title="Conservation Mode (85% – 90%)",
            subtitle="Preserves battery cell health when predominantly on AC power"
        )
        row_conserve.add_prefix(make_icon_prefix("󰌪"))
        btn_conserve = Gtk.Button(label="Apply Limit")
        btn_conserve.add_css_class("apple-pill-btn")
        btn_conserve.set_valign(Gtk.Align.CENTER)
        btn_conserve.connect("clicked", lambda b: self.set_profile(85, 90))
        row_conserve.add_suffix(btn_conserve)
        grp_limits.add(row_conserve)

        row_boost = Adw.ActionRow(
            title="Fast Charge Boost (100% Trip Mode)",
            subtitle="Allows 100% full charge for travel and extended battery work"
        )
        row_boost.add_prefix(make_icon_prefix("󰂄"))
        btn_boost = Gtk.Button(label="Charge to 100%")
        btn_boost.add_css_class("apple-pill-btn")
        btn_boost.set_valign(Gtk.Align.CENTER)
        btn_boost.connect("clicked", lambda b: self.set_profile(95, 100))
        row_boost.add_suffix(btn_boost)
        grp_limits.add(row_boost)

        row_gauge = Adw.ActionRow(
            title="ThinkPad Lid Dot Percentage Gauge",
            subtitle="Flash the physical lid red LED dot with current battery percentage"
        )
        row_gauge.add_prefix(make_icon_prefix("󰛄"))
        btn_gauge = Gtk.Button(label="Flash Lid Dot")
        btn_gauge.add_css_class("apple-pill-btn")
        btn_gauge.set_valign(Gtk.Align.CENTER)
        btn_gauge.connect("clicked", lambda b: subprocess.Popen(["thinkdot", "gauge"]))
        row_gauge.add_suffix(btn_gauge)
        grp_limits.add(row_gauge)

        row_accu = Adw.ActionRow(
            title="AccuBattery Diagnostics & Live Graphs",
            subtitle="Deep degradation tracking, charging curves, and per-app usage"
        )
        row_accu.add_prefix(make_icon_prefix("󰁹"))
        btn_accu = Gtk.Button(label="Open AccuBattery")
        btn_accu.add_css_class("apple-pill-btn")
        btn_accu.set_valign(Gtk.Align.CENTER)
        btn_accu.connect("clicked", lambda b: subprocess.Popen(["accubattery-gui"]))
        row_accu.add_suffix(btn_accu)
        grp_limits.add(row_accu)

        # ── Group 4: Architecture & Speed Optimization Guide ──
        grp_notes = Adw.PreferencesGroup(title="Speeding Up Charging Architecture")
        self.pref_page.add(grp_notes)

        row_n1 = Adw.ActionRow(
            title="USB-C PD Power Headroom",
            subtitle="Using a 65W or 100W PD charger guarantees maximum 45W charging speed concurrently with full CPU boost."
        )
        row_n1.add_prefix(make_icon_prefix("󰚥"))
        grp_notes.add(row_n1)

        row_n2 = Adw.ActionRow(
            title="Battery Chemistry (CC vs CV Curve)",
            subtitle="Fastest charging occurs from 0% to 80%. Above 80%, lithium chemistry naturally tapers current to protect cell chemistry."
        )
        row_n2.add_prefix(make_icon_prefix("󱐋"))
        grp_notes.add(row_n2)

        row_n3 = Adw.ActionRow(
            title="Chassis Cooling & Thermals",
            subtitle="Active cooling on AC power prevents the embedded controller from thermally throttling battery charge speed."
        )
        row_n3.add_prefix(make_icon_prefix("󰻠"))
        grp_notes.add(row_n3)

        self.refresh_data()

    def set_profile(self, start: int, stop: int):
        bat_dir = "/sys/class/power_supply/BAT0"
        for f in [f"{bat_dir}/charge_start_threshold", f"{bat_dir}/charge_control_start_threshold"]:
            if os.path.exists(f) and os.access(f, os.W_OK):
                try:
                    open(f, "w").write(str(start))
                except Exception:
                    pass
        for f in [f"{bat_dir}/charge_stop_threshold", f"{bat_dir}/charge_control_end_threshold"]:
            if os.path.exists(f) and os.access(f, os.W_OK):
                try:
                    open(f, "w").write(str(stop))
                except Exception:
                    pass
        if shutil.which("batmon"):
            opt = "--trip" if stop >= 100 else "--conserve"
            subprocess.run(["batmon", opt], capture_output=True)
        self.refresh_data()

    def refresh_data(self):
        bat_dir = "/sys/class/power_supply/BAT0"
        if not os.path.exists(bat_dir):
            bat_dir = "/sys/class/power_supply/BAT1"
        if not os.path.exists(bat_dir):
            return

        try:
            cap = int(open(f"{bat_dir}/capacity").read().strip())
            status = open(f"{bat_dir}/status").read().strip()
            cycles = open(f"{bat_dir}/cycle_count").read().strip() if os.path.exists(f"{bat_dir}/cycle_count") else "N/A"

            efull = int(open(f"{bat_dir}/energy_full").read().strip()) if os.path.exists(f"{bat_dir}/energy_full") else 0
            edesign = int(open(f"{bat_dir}/energy_full_design").read().strip()) if os.path.exists(f"{bat_dir}/energy_full_design") else 1
            pnow = int(open(f"{bat_dir}/power_now").read().strip()) if os.path.exists(f"{bat_dir}/power_now") else 0
            vnow = int(open(f"{bat_dir}/voltage_now").read().strip()) if os.path.exists(f"{bat_dir}/voltage_now") else 0

            health_pct = (efull * 100.0) / edesign if edesign > 0 else 100.0
            wh_full = efull / 1_000_000
            wh_design = edesign / 1_000_000
            watts = pnow / 1_000_000
            volts = vnow / 1_000_000

            cond = "Normal" if health_pct >= 80.0 else "Service Recommended"
            cond_class = "apple-status-green" if health_pct >= 80.0 else "apple-status-orange"
            set_badge(self.lbl_health_badge, f"{health_pct:.1f}% · {cond}", cond_class)
            set_badge(self.lbl_energy_badge, f"{wh_full:.1f} / {wh_design:.1f} Wh", "apple-status-accent")
            set_badge(self.lbl_cycles_badge, f"{cycles} cycles", "apple-status-accent")

            stat_class = "apple-status-green" if status == "Charging" else ("apple-status-orange" if status == "Discharging" else "apple-status-accent")
            set_badge(self.lbl_flow_level, f"{cap}% [{status}]", stat_class)

            pwr_sign = "+" if status == "Charging" else ("-" if status == "Discharging" else "")
            set_badge(self.lbl_flow_speed, f"{pwr_sign}{watts:.1f} W ({volts:.1f} V)", stat_class)

            time_est = "N/A"
            if shutil.which("upower"):
                up_res = subprocess.run(["upower", "-i", "/org/freedesktop/UPower/devices/battery_BAT0"], capture_output=True, text=True)
                for line in up_res.stdout.splitlines():
                    if "time to full" in line or "time to empty" in line:
                        parts = line.split(":")
                        if len(parts) >= 2:
                            time_est = parts[1].strip()
                            break
            set_badge(self.lbl_flow_time, time_est, "apple-status-accent")
        except Exception:
            pass

if __name__ == "__main__":
    app = ControlCenterApp()
    sys.exit(app.run(sys.argv))

