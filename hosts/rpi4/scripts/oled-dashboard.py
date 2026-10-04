#!/usr/bin/env python3
"""
RPi4 Homelab OLED Dashboard
────────────────────────────
Drives a 128×64 monochrome I2C OLED (SSD1306, SH1106, SSD1309) via smbus2.
Built-in driver — no luma.oled needed.

Auto-detects I2C address (0x3C or 0x3D) on the configured bus.
Supports SH1106 (common on AliExpress) by trying both column offsets.

ENV overrides:
  OLED_I2C_BUS   (default: 1)
  OLED_I2C_ADDR  (default: auto-detect)
  OLED_DRIVER    (default: auto — try "ssd1306" or "sh1106")
"""

from __future__ import annotations

import os, sys, time, signal, socket, subprocess
from datetime import datetime
from pathlib import Path
from typing import Optional

import smbus2
import psutil
from PIL import Image, ImageDraw, ImageFont

# ═══════════════════════════════════════════════════════════════════════════════
#  Display geometry
# ═══════════════════════════════════════════════════════════════════════════════
WIDTH  = 128
HEIGHT = 64
PAGES  = HEIGHT // 8

# ═══════════════════════════════════════════════════════════════════════════════
#  Command constants (shared between SSD1306 and SH1106)
# ═══════════════════════════════════════════════════════════════════════════════
CMD_DISPLAY_OFF    = 0xAE
CMD_DISPLAY_ON     = 0xAF
CMD_SET_CONTRAST   = 0x81
CMD_NORMAL_DISPLAY = 0xA6
CMD_DISPLAY_RAM    = 0xA4
CMD_SET_MUX        = 0xA8
CMD_SET_OFFSET     = 0xD3
CMD_SET_START_LINE = 0x40
CMD_SEG_REMAP      = 0xA1
CMD_COM_SCAN_DEC   = 0xC8
CMD_COM_PINS       = 0xDA
CMD_SET_CLK        = 0xD5
CMD_SET_PRECHARGE  = 0xD9
CMD_VCOM_DETECT    = 0xDB
CMD_CHARGE_PUMP    = 0x8D
CMD_MEM_MODE       = 0x20   # SSD1306 only
CMD_COL_ADDR       = 0x21   # SSD1306 only
CMD_PAGE_ADDR      = 0x22   # SSD1306 only

INIT_CMDS = [
    CMD_DISPLAY_OFF,
    CMD_SET_CLK,     0x80,
    CMD_SET_MUX,     0x3F,
    CMD_SET_OFFSET,  0x00,
    CMD_SET_START_LINE | 0x00,
    CMD_CHARGE_PUMP, 0x14,
    CMD_SEG_REMAP,
    CMD_COM_SCAN_DEC,
    CMD_COM_PINS,    0x12,
    CMD_SET_CONTRAST,0xCF,
    CMD_SET_PRECHARGE,0xF1,
    CMD_VCOM_DETECT, 0x40,
    CMD_DISPLAY_RAM,
    CMD_NORMAL_DISPLAY,
    CMD_DISPLAY_ON,
]


class OLEDBase:
    """Shared I2C init; subclasses override display()."""

    def __init__(self, bus_id: int, address: int):
        self.bus  = smbus2.SMBus(bus_id)
        self.addr = address
        for cmd in INIT_CMDS:
            self._cmd(cmd)

    def _cmd(self, byte: int) -> None:
        self.bus.write_byte_data(self.addr, 0x00, byte)

    def _data(self, chunk: list[int]) -> None:
        self.bus.write_i2c_block_data(self.addr, 0x40, chunk)

    def clear(self) -> None:
        self.display(Image.new("1", (WIDTH, HEIGHT), 0))

    def close(self) -> None:
        try:
            self.clear()
            self._cmd(CMD_DISPLAY_OFF)
        except Exception:
            pass
        self.bus.close()

    def display(self, image: Image.Image) -> None:
        raise NotImplementedError


class SSD1306(OLEDBase):
    """Horizontal addressing mode — one DMA-style burst per frame."""

    def __init__(self, bus_id: int, address: int):
        super().__init__(bus_id, address)
        # Switch to horizontal addressing
        self._cmd(CMD_MEM_MODE); self._cmd(0x00)

    def display(self, image: Image.Image) -> None:
        # Set full column and page range
        self._cmd(CMD_COL_ADDR);  self._cmd(0);  self._cmd(WIDTH - 1)
        self._cmd(CMD_PAGE_ADDR); self._cmd(0);  self._cmd(PAGES - 1)
        buf = _image_to_buf(image)
        for i in range(0, len(buf), 32):
            self._data(list(buf[i:i + 32]))


class SH1106(OLEDBase):
    """Page-addressed (column offset +2, one page write per row)."""

    COL_OFFSET = 2  # SH1106 has 132-col internal memory; visible starts at col 2

    def display(self, image: Image.Image) -> None:
        buf = _image_to_buf(image)
        for page in range(PAGES):
            self._cmd(0xB0 | page)                          # page address
            self._cmd(0x00 | ((self.COL_OFFSET) & 0x0F))   # low nibble of col
            self._cmd(0x10 | ((self.COL_OFFSET) >> 4))     # high nibble of col
            start = page * WIDTH
            self._data(list(buf[start:start + WIDTH]))


def _image_to_buf(image: Image.Image) -> bytearray:
    """Convert 128×64 1-bit PIL image → SSD1306/SH1106 page buffer."""
    buf = bytearray(WIDTH * PAGES)
    px = image.load()
    for x in range(WIDTH):
        for page in range(PAGES):
            byte = 0
            for bit in range(8):
                y = page * 8 + bit
                if y < HEIGHT and px[x, y]:
                    byte |= (1 << bit)
            buf[page * WIDTH + x] = byte
    return buf


def auto_detect_oled(bus_id: int) -> tuple[OLEDBase, str]:
    """
    Try addresses 0x3C and 0x3D, then drivers SSD1306 → SH1106.
    Returns (driver_instance, description).
    Raises RuntimeError if nothing responds.
    """
    for addr in [0x3C, 0x3D]:
        for DriverClass, name in [(SSD1306, "SSD1306"), (SH1106, "SH1106")]:
            try:
                drv = DriverClass(bus_id, addr)
                # Write a test pattern to confirm it's alive
                drv.clear()
                return drv, f"{name}@0x{addr:02X}"
            except Exception:
                pass
    raise RuntimeError(f"No OLED found on I2C bus {bus_id} at 0x3C or 0x3D")


# ═══════════════════════════════════════════════════════════════════════════════
#  System metric collectors
# ═══════════════════════════════════════════════════════════════════════════════

def _read(path: str, default: str = "") -> str:
    try:
        return Path(path).read_text().strip()
    except Exception:
        return default


def cpu_pct() -> float:
    return psutil.cpu_percent(interval=None)


def mem_info() -> tuple[float, float]:
    m = psutil.virtual_memory()
    return m.used / 1e9, m.total / 1e9


def cpu_temp() -> Optional[float]:
    try:
        for key in ("cpu_thermal", "cpu-thermal", "coretemp", "k10temp", "acpitz"):
            entries = psutil.sensors_temperatures().get(key, [])
            if entries:
                return entries[0].current
    except Exception:
        pass
    for i in range(10):
        raw = _read(f"/sys/class/thermal/thermal_zone{i}/temp")
        if raw.isdigit():
            return int(raw) / 1000.0
    return None


def disk_info() -> tuple[float, float]:
    d = psutil.disk_usage("/")
    return d.used / 1e9, d.total / 1e9


def uptime_str() -> str:
    try:
        s = int(time.time() - psutil.boot_time())
        h, r = divmod(s, 3600)
        m = r // 60
        return f"{h//24}d{h%24}h" if h >= 24 else f"{h:02d}h{m:02d}m"
    except Exception:
        return "?"


def local_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("1.1.1.1", 53))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "no network"


def service_counts() -> tuple[int, int]:
    try:
        running = subprocess.run(
            ["systemctl", "--type=service", "--state=running",
             "list-units", "--no-pager", "--no-legend"],
            capture_output=True, text=True, timeout=3
        ).stdout.strip().splitlines()
        total = subprocess.run(
            ["systemctl", "--type=service",
             "list-units", "--no-pager", "--no-legend"],
            capture_output=True, text=True, timeout=3
        ).stdout.strip().splitlines()
        return len(running), len(total)
    except Exception:
        return 0, 0


class NetRates:
    def __init__(self):
        c = psutil.net_io_counters()
        self._t, self._rx, self._tx = time.monotonic(), c.bytes_recv, c.bytes_sent
        self.rx_kbps = self.tx_kbps = 0.0

    def update(self):
        now = time.monotonic()
        c   = psutil.net_io_counters()
        dt  = max(now - self._t, 0.001)
        self.rx_kbps = max((c.bytes_recv - self._rx) / dt / 1024, 0.0)
        self.tx_kbps = max((c.bytes_sent - self._tx) / dt / 1024, 0.0)
        self._t, self._rx, self._tx = now, c.bytes_recv, c.bytes_sent


_net = NetRates()

# ═══════════════════════════════════════════════════════════════════════════════
#  Fonts — search multiple paths; fall back to PIL default
# ═══════════════════════════════════════════════════════════════════════════════

_FONT_CANDIDATES = [
    "/run/current-system/sw/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/run/current-system/sw/share/fonts/truetype/DejaVuSansMono.ttf",
    "/nix/var/nix/profiles/system/sw/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
]

def _font(size: int) -> ImageFont.ImageFont:
    for p in _FONT_CANDIDATES:
        if os.path.isfile(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    # PIL built-in 8-px bitmap font — always works
    return ImageFont.load_default()


FONT_HOST = _font(9)   # hostname row
FONT_DATA = _font(8)   # all data rows
FONT_TIME = _font(8)   # clock

# ═══════════════════════════════════════════════════════════════════════════════
#  Layout
# ═══════════════════════════════════════════════════════════════════════════════
HEADER_H = 12     # header strip height in px
SEP_Y    = HEADER_H
ROW_H    = 10     # each data row height
COL_B    = 66     # x-start of right column

TICK_CHARS = ["●", "◑", "○", "◐"]

# ─── Shared mutable state (set by main, read by renderer) ────────────────────
_cached_ip:   str         = "..."
_cached_svcs: tuple[int,int] = (0, 0)


# ═══════════════════════════════════════════════════════════════════════════════
#  Drawing helpers
# ═══════════════════════════════════════════════════════════════════════════════

def _bar(draw: ImageDraw.ImageDraw, x: int, y: int, w: int, h: int, pct: float) -> None:
    draw.rectangle([x, y, x + w - 1, y + h - 1], outline=1, fill=0)
    fill = int((w - 2) * max(0.0, min(pct / 100.0, 1.0)))
    if fill > 0:
        draw.rectangle([x + 1, y + 1, x + fill, y + h - 2], fill=1)


# ═══════════════════════════════════════════════════════════════════════════════
#  Frame renderer
# ═══════════════════════════════════════════════════════════════════════════════
HOSTNAME = socket.gethostname().replace("nixos-", "")


def render(tick: int) -> Image.Image:
    global _cached_ip, _cached_svcs

    img  = Image.new("1", (WIDTH, HEIGHT), 0)
    d    = ImageDraw.Draw(img)
    now  = datetime.now()

    # ── Header: hostname | clock ────────────────────────────────────────────
    d.text((1, 2), HOSTNAME, font=FONT_HOST, fill=1)
    ts = now.strftime("%H:%M")
    hb = TICK_CHARS[tick % 4]
    ts_w = int(d.textlength(ts, font=FONT_TIME))
    d.text((WIDTH - ts_w - 8, 2), ts, font=FONT_TIME, fill=1)
    d.text((WIDTH - 7, 2), hb, font=FONT_TIME, fill=1)

    # Separator
    d.line([(0, SEP_Y), (WIDTH - 1, SEP_Y)], fill=1)

    # ── Metrics ─────────────────────────────────────────────────────────────
    _net.update()
    cpu    = cpu_pct()
    mu, mt = mem_info()
    du, dt = disk_info()
    temp   = cpu_temp()
    up     = uptime_str()
    sv_r, sv_t = _cached_svcs
    rx, tx = _net.rx_kbps, _net.tx_kbps

    mem_pct  = 100 * mu / max(mt, 0.001)
    disk_pct = 100 * du / max(dt, 0.001)

    def row(y, la, va, lb=None, vb=None, pct_a=None, pct_b=None):
        """Draw one data row (two columns)."""
        d.text((1, y), la, font=FONT_DATA, fill=1)
        d.text((21, y), va, font=FONT_DATA, fill=1)
        if pct_a is not None:
            _bar(d, 52, y + 1, 12, 6, pct_a)
        if lb is not None:
            d.text((COL_B, y), lb, font=FONT_DATA, fill=1)
        if vb is not None:
            d.text((COL_B + 18, y), vb, font=FONT_DATA, fill=1)
        if pct_b is not None:
            _bar(d, COL_B + 46, y + 1, 12, 6, pct_b)

    y = SEP_Y + 2
    row(y,
        "CPU", f"{cpu:.0f}%", pct_a=cpu,
        lb="TMP", vb=(f"{temp:.0f}C" if temp else "?"))
    y += ROW_H
    row(y,
        "RAM", f"{mu:.1f}G", pct_a=mem_pct,
        lb="UP",  vb=up)
    y += ROW_H
    row(y,
        "DSK", f"{du:.0f}G",  pct_a=disk_pct,
        lb="SVC", vb=f"{sv_r}/{sv_t}")
    y += ROW_H

    # Net row — full width, arrows
    def _kbps(v):
        return f"{v/1024:.1f}M" if v >= 1024 else f"{v:.0f}K"
    d.text((1, y), f"RX {_kbps(rx)}", font=FONT_DATA, fill=1)
    d.text((COL_B, y), f"TX {_kbps(tx)}", font=FONT_DATA, fill=1)
    y += ROW_H

    # IP row — full width
    d.text((1, y), f"IP {_cached_ip}", font=FONT_DATA, fill=1)

    return img


# ═══════════════════════════════════════════════════════════════════════════════
#  Main loop
# ═══════════════════════════════════════════════════════════════════════════════
I2C_BUS        = int(os.environ.get("OLED_I2C_BUS", "1"))
OLED_ADDR_ENV  = os.environ.get("OLED_I2C_ADDR", "")
OLED_DRIVER    = os.environ.get("OLED_DRIVER", "auto")
REFRESH_S      = 1.0
IP_TTL_S       = 30.0
SVC_TTL_S      = 15.0
RETRY_S        = 5.0

_alive = True

def _stop(sig, frame):
    global _alive
    _alive = False

signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT,  _stop)


def _make_driver() -> OLEDBase:
    if OLED_ADDR_ENV:
        addr = int(OLED_ADDR_ENV, 16)
        if OLED_DRIVER == "sh1106":
            return SH1106(I2C_BUS, addr)
        return SSD1306(I2C_BUS, addr)
    return auto_detect_oled(I2C_BUS)[0]


def main() -> None:
    global _cached_ip, _cached_svcs, _alive

    # Warm caches
    _cached_ip   = local_ip()
    _cached_svcs = service_counts()

    t_ip  = time.monotonic()
    t_svc = time.monotonic()

    oled: Optional[OLEDBase] = None
    tick = 0

    while _alive:
        # ── Connect / reconnect ──────────────────────────────────────────────
        if oled is None:
            try:
                if OLED_ADDR_ENV:
                    addr = int(OLED_ADDR_ENV, 16)
                    drv  = SSD1306(I2C_BUS, addr) if OLED_DRIVER != "sh1106" else SH1106(I2C_BUS, addr)
                    desc = f"{OLED_DRIVER}@0x{addr:02X}"
                else:
                    drv, desc = auto_detect_oled(I2C_BUS)
                oled = drv
                print(f"[oled] Connected: {desc} on bus {I2C_BUS}", flush=True)
            except Exception as e:
                print(f"[oled] Init failed ({e}) — retrying in {RETRY_S:.0f}s", flush=True)
                time.sleep(RETRY_S)
                continue

        # ── Slow cache refreshes ─────────────────────────────────────────────
        now = time.monotonic()
        if now - t_ip >= IP_TTL_S:
            _cached_ip = local_ip()
            t_ip = now
        if now - t_svc >= SVC_TTL_S:
            _cached_svcs = service_counts()
            t_svc = now

        # ── Render + push ────────────────────────────────────────────────────
        try:
            oled.display(render(tick))
        except Exception as e:
            print(f"[oled] Render/push error ({e}) — reconnecting", flush=True)
            try:
                oled.close()
            except Exception:
                pass
            oled = None
            time.sleep(RETRY_S)
            continue

        tick += 1
        time.sleep(REFRESH_S)

    # ── Graceful shutdown ────────────────────────────────────────────────────
    if oled:
        try:
            img = Image.new("1", (WIDTH, HEIGHT), 0)
            d   = ImageDraw.Draw(img)
            d.text((10, 26), "Shutting down...", font=FONT_DATA, fill=1)
            oled.display(img)
            time.sleep(1.5)
            oled.close()
        except Exception:
            pass
    print("[oled] Stopped.", flush=True)


if __name__ == "__main__":
    main()
