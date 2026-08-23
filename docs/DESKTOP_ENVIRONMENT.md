# Desktop Environment & User Interface Technical Specification

This document provides a 100% exhaustive technical reference for the Hyprland Wayland compositor, Greetd login manager, Hyprlock, Hypridle, Waybar, SwayNC, Rofi, Kitty, Firefox `user.js` performance tuning, Matugen Material You dynamic engine, default MIME applications, custom helper scripts, and complete keybinding matrices defined in `modules/desktop.nix`, `hosts/desktop/home.nix`, and `hosts/desktop/home-theming.nix`.

---

## 1. Display Manager & Session Startup

### Greetd + Tuigreet (`modules/desktop.nix`)
- **Service**: `services.greetd.enable = true`
- **Greeter Command**: `${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd Hyprland`
- **Greeter User**: `greeter`
- **Authenticators**: `security.polkit.enable = true`, PAM service `security.pam.services.hyprlock = {}`.

### XDG Portals & Desktop Integration
- **Portal Implementation**: `xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ]`
- **Portal Configuration**: `xdg.portal.config.common.default = "*"`
- **Dconf**: `programs.dconf.enable = true` (Allows Home Manager GTK/dconf themes to apply globally).

---

## 2. Dynamic Material You Design Engine (Matugen `home-theming.nix`)

The desktop features a full Material Design 3 dynamic palette generator via **Matugen**. Whenever a wallpaper is changed, Matugen extracts the primary, secondary, and tertiary HSL color schemes and auto-generates theme files across all applications:

1. **Starship Prompt** (`~/.config/matugen/templates/starship.toml`) — Powerline prompt with dynamic segment background colors.
2. **Hyprland Compositor** (`~/.config/matugen/templates/hyprland-colors.conf`) — Dynamic active/inactive window border RGBA colors.
3. **Waybar Status Bar** (`~/.config/matugen/templates/waybar-colors.css`) — Glassmorphism CSS color variables.
4. **Kitty Terminal** (`~/.config/matugen/templates/kitty-colors.conf`) — 16-color ANSI terminal palette + cursor/selection colors.
5. **Rofi Menus** (`~/.config/matugen/templates/rofi-colors.rasi`) — Background, selection, text, and accent colors.
6. **SwayNC Notification Center** (`~/.config/matugen/templates/swaync-colors.css`) — Notification card colors.
7. **VS Code / Continue Extension** (`~/.config/matugen/templates/vscode-theme.json`) — Complete editor syntax & UI color theme.
8. **Firefox Browser** (`~/.config/matugen/templates/theme-material-blue.css`) — Applied via `userChrome.css` and `userContent.css`.
9. **Btop System Monitor** (`~/.config/matugen/templates/btop.theme`) — Custom CPU/RAM/Net graph color gradients.
10. **Steam Client** (`~/.config/matugen/templates/steam.css`) — Millennium client CSS theme overlay.
11. **GTK3 / GTK4 & Libadwaita** (`~/.config/matugen/templates/gtk3.css`, `gtk4.css`) — App window, headerbar, popover colors.
12. **KDE / Qt Applications** (`~/.config/matugen/templates/kde-colors.colors`) — Dynamic palette for Dolphin and Qt desktop applications.

---

## 3. Firefox High-Performance & Privacy Engine (`hosts/desktop/home.nix`)

Configured in `home.file.".mozilla/firefox/1arj8uom.default/user.js"`:

### Hardware GPU Acceleration
- `gfx.webrender.all = true`
- `gfx.webrender.compositor = true`
- `media.hardware-video-decoding.enabled = true`
- `media.ffmpeg.vaapi.enabled = true` (AMD GPU VA-API hardware video decoding).

### 1GB In-RAM Cache (Instant Tab Navigation)
- `browser.cache.memory.enable = true`
- `browser.cache.memory.capacity = 1048576` (Allocates 1 GB RAM for browser memory cache).
- `browser.tabs.remote.warmup.enabled = true`

### Privacy & Telemetry Purge
- `DisableTelemetry = true`, `DisableFirefoxStudies = true`, `DisablePocket = true`.
- `toolkit.telemetry.enabled = false`, `browser.newtabpage.activity-stream.telemetry = false`, `browser.ping-centre.telemetry = false`.

---

## 4. Default Applications (XDG MIME Handlers)

Defined in `hosts/desktop/configuration.nix` (`xdg.mime.defaultApplications`):

| File Type / Protocol | MIME Type | Default Application | Desktop File |
| :--- | :--- | :--- | :--- |
| **PDF Documents** | `application/pdf` | Zathura | `org.pwmt.zathura.desktop` |
| **PNG Images** | `image/png` | Loupe | `org.gnome.Loupe.desktop` |
| **JPEG Images** | `image/jpeg` | Loupe | `org.gnome.Loupe.desktop` |
| **WebP Images** | `image/webp` | Loupe | `org.gnome.Loupe.desktop` |
| **GIF Images** | `image/gif` | Loupe | `org.gnome.Loupe.desktop` |
| **SVG Vectors** | `image/svg+xml` | Loupe | `org.gnome.Loupe.desktop` |
| **MP4 Videos** | `video/mp4` | VLC Media Player | `vlc.desktop` |
| **MKV Videos** | `video/x-matroska` | VLC Media Player | `vlc.desktop` |
| **WebM Videos** | `video/webm` | VLC Media Player | `vlc.desktop` |
| **QuickTime Videos**| `video/quicktime` | VLC Media Player | `vlc.desktop` |
| **Word Documents** | `application/vnd.openxmlformats-officedocument.wordprocessingml.document`, `application/msword`, `application/vnd.oasis.opendocument.text` | LibreOffice Writer | `libreoffice-writer.desktop` |
| **Spreadsheets** | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`, `application/vnd.ms-excel` | LibreOffice Calc | `libreoffice-calc.desktop` |
| **Presentations** | `application/vnd.openxmlformats-officedocument.presentationml.presentation` | LibreOffice Impress | `libreoffice-impress.desktop` |
| **Web Browsing** | `x-scheme-handler/http`, `x-scheme-handler/https` | Firefox | `firefox.desktop` |
| **3D Printing** | `x-scheme-handler/lycheeslicer` | Lychee Slicer | `Lychee Slicer.desktop` |

---

## 5. Hyprland Window & Workspace Rules (`hosts/desktop/home.nix`)

- **PulseAudio Volume Control**: `windowrule = float 1`, `size 700 500`, `center 1` (`pwvucontrol`).
- **GNOME Calendar**: `windowrule = float 1`, `size 850 600`, `center 1` (`org.gnome.Calendar`).
- **Network TUI**: `windowrule = float 1`, `size 700 500`, `center 1` (`network_tui`).
- **Scratchpad Terminal**: `windowrule = float 1`, `size 2176 1008`, `center 1` (`scratchpad`).
- **Steam Games Performance Bypass**:
  - `windowrule = no_anim 1, match:class ^(steam_app_.*)$`
  - `windowrule = no_shadow 1, match:class ^(steam_app_.*)$`
  - `windowrule = no_blur 1, match:class ^(steam_app_.*)$`  
  *(Completely disables window animations, shadows, and blur passes when Steam games are focused to eliminate compositor latency).*

---

## 6. Hyprlock & Hypridle Daemon Configuration

### Hyprlock Screen Locker (`programs.hyprlock`)
- **Grace Period**: 15 seconds (`grace = 15`).
- **Options**: `disable_loading_bar = true`, `hide_cursor = true`.
- **Background**: Live desktop screenshot with 3 blur passes and size 8.
- **Input Field**: Mauve outline (`rgba(203, 166, 247, 1.0)`), dark inner (`rgba(30, 30, 46, 0.9)`), custom placeholder `Password...`.

### Hypridle Idle Manager (`services.hypridle`)
- **15 Minutes (900s)**: Executes `hyprlock` to lock the screen.
- **30 Minutes (1800s)**: Executes `hyprctl dispatch dpms off` (turns off monitor power); restores on activity (`dpms on`).

---

## 7. Status Bar Architecture (Waybar `hosts/desktop/home.nix`)

```jsonc
"modules-left": ["hyprland/workspaces", "hyprland/submap"],
"modules-center": ["clock", "custom/pomodoro", "clock#date"],
"modules-right": ["mpris", "idle_inhibitor", "custom/ai-ambient", "custom/sysinfo", "memory", "disk", "pulseaudio", "network", "custom/notification", "tray", "custom/power"]
```

- **`hyprland/submap`**: Displays active keybinding submap mode (e.g. `split`).
- **`custom/ai-ambient`**: Executed every 300s via `bash ~/.config/waybar/scripts/ai_ambient.sh`. Displays rotating AI tips/observations with system tooltips. Styled with italic `@tertiary` accent color.

---

## 8. Complete Hyprland Keybindings Matrix

Defined in `hosts/desktop/home.nix` (`$mod = SUPER`):

### Application Launchers & Windows
| Modifier + Key | Command / Execution | Description |
| :--- | :--- | :--- |
| `$mod + RETURN` | `kitty` | Launch Kitty GPU Terminal |
| `$mod + Q` | `hyprctl dispatch killactive` | Close active window |
| `$mod + F` | `hyprctl dispatch togglefloating` | Toggle window floating state |
| `$mod + M` | `hyprctl dispatch fullscreen 1` | Toggle pseudo-fullscreen mode |
| `$mod + SHIFT + M` | `hyprctl dispatch fullscreen 0` | Toggle true fullscreen mode |
| `$mod + P` | `hyprctl dispatch pseudo` | Toggle Dwindle pseudo tiling |
| `$mod + J` | `hyprctl dispatch togglesplit` | Toggle Dwindle split direction |
| `$mod + E` | `kitty -e yazi` | Launch Yazi terminal file manager |
| `$mod + SHIFT + E` | `nautilus` | Launch GNOME Nautilus file manager |
| `$mod + B` | `firefox` | Launch Firefox web browser |

### 🔲 Split / Resize Mode Submap (`SUPER + R`)
Pressing **`SUPER + R`** enters the `split` submap mode (indicated visually in Waybar). Inside this submap:

| Key Press | Executed Action | Resulting Layout / Behavior |
| :--- | :--- | :--- |
| `1` | `resize_split.sh width 25` | Set left active window width to 25% of monitor width |
| `2` | `resize_split.sh width 33` | Set left active window width to 33% of monitor width |
| `3` | `resize_split.sh width 50` | Set left active window width to 50% of monitor width |
| `4` | `resize_split.sh width 66` | Set left active window width to 66% of monitor width |
| `5` | `resize_split.sh width 75` | Set left active window width to 75% of monitor width |
| `H` | `resize_split.sh height 50` | Set top active window height to 50% of monitor height |
| `6` / `F` | `hyprctl dispatch fullscreen 1` | Toggle pseudo-fullscreen mode |
| `Escape` / `Return` / `SUPER + R` | `submap reset` | Reset submap and return to default keybinding mode |

### System & Power Menus
| Modifier + Key | Command / Execution | Description |
| :--- | :--- | :--- |
| `$mod + L` | `hyprlock` | Lock screen immediately |
| `$mod + ESCAPE` | `power_menu.sh` | Open Rofi Power Menu (Lock, Suspend, Reboot, Shutdown, Exit) |
| `$mod + SHIFT + W` | `change_wallpaper.sh` | Cycle wallpaper background |

### AI, Clipboard & Notifications
| Modifier + Key | Command / Execution | Description |
| :--- | :--- | :--- |
| `$mod + D` / `$mod + SPACE` | `spotlight.sh` | Open Spotlight Search (Apps, Files, AI Answer fallback) |
| `$mod + A` | `rofi_ai.sh` | Open Rofi AI Assistant popup |
| `$mod + V` | `cliphist_picker.sh` | Open Rofi Clipboard History picker |
| `$mod + ALT + N` | `notification_digest.sh` | Trigger AI Notification Digest popup |
| `$mod + SHIFT + S` | `ai_ocr_screenshot.sh` | Capture region screenshot & analyze with Multimodal Vision AI |

### Screenshots
| Modifier + Key | Command / Execution | Description |
| :--- | :--- | :--- |
| `Print` | `grim -g "$(slurp)" - \| wl-copy` | Region screenshot to clipboard |
| `SHIFT + Print` | `grim - \| wl-copy` | Fullscreen screenshot to clipboard |
| `CTRL + Print` | Focused window capture to `wl-copy` | Active window screenshot to clipboard |

### Focus & Workspace Navigation
| Modifier + Key | Command / Execution | Description |
| :--- | :--- | :--- |
| `$mod + LEFT / RIGHT / UP / DOWN` | `movefocus, l / r / u / d` | Focus adjacent window |
| `$mod + 1 .. 9` | `workspace, 1 .. 9` | Switch active workspace |
| `$mod + SHIFT + 1 .. 9` | `movetoworkspace, 1 .. 9` | Move window to workspace |
| `$mod + Mouse Scroll Down/Up` | `workspace, e+1 / e-1` | Cycle workspace |
| `$mod + SHIFT + Mouse Side 275/276` | `movetoworkspace, r-1 / r+1` | Move window relative workspace |

### Virtual Terminal (TTY) Switching
| Modifier + Key | Command / Execution | Description |
| :--- | :--- | :--- |
| `CTRL + ALT + F1 .. F12` | `chvt 1 .. 12` | Switch to virtual console TTY 1..12 |

### Hardware & Volume Controls (OSD Toast Overlays)
| Modifier + Key | Command / Execution | Description |
| :--- | :--- | :--- |
| `XF86AudioRaiseVolume` | `volume_osd.sh up` (`wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+`) | Raise volume + show OSD |
| `XF86AudioLowerVolume` | `volume_osd.sh down` (`wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-`) | Lower volume + show OSD |
| `XF86AudioMute` | `volume_osd.sh mute` (`wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle`) | Toggle audio mute + show OSD |
| `XF86AudioMicMute` | `wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle` | Toggle mic mute |
| `XF86MonBrightnessUp` | `brightness_osd.sh up` (`ddcutil setvcp 10 + 5`) | Increase monitor brightness + show OSD |
| `XF86MonBrightnessDown` | `brightness_osd.sh down` (`ddcutil setvcp 10 - 5`) | Decrease monitor brightness + show OSD |
