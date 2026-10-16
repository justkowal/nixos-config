#!/usr/bin/env python3
"""Read SCD41 (CO2) and BME280 (climate) over I2C, push to VictoriaMetrics, keep /run/sensors/latest.json fresh."""

import json
import os
import struct
import sys
import time
import urllib.request

from smbus2 import SMBus, i2c_msg

BUS = int(os.environ.get("I2C_BUS", "1"))
SCD41_ADDR = int(os.environ.get("SCD41_ADDR", "0x62"), 16)
BME280_ADDR = int(os.environ.get("BME280_ADDR", "0x76"), 16)
VM_IMPORT = os.environ.get("VM_IMPORT_URL", "http://127.0.0.1:8428/api/v1/import/prometheus")
NTFY_URL = os.environ.get("NTFY_URL", "https://ntfy.lab/alerts")
STATE_FILE = os.environ.get("STATE_FILE", "/run/sensors/latest.json")
CO2_HIGH = int(os.environ.get("CO2_HIGH", "1200"))
CO2_CLEAR = int(os.environ.get("CO2_CLEAR", "800"))
INTERVAL = 5.0  # scd41 periodic mode produces a sample every 5 s


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def crc8(data: bytes) -> int:
    crc = 0xFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ 0x31) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


class SCD41:
    def __init__(self, bus: SMBus, addr: int):
        self.bus, self.addr = bus, addr
        # a previous run may have left it in periodic mode, where most commands are rejected
        self._cmd(0x3F86)
        time.sleep(0.5)
        self._cmd(0x21B1)

    def _cmd(self, cmd: int, arg: int | None = None) -> None:
        data = list(struct.pack(">H", cmd))
        if arg is not None:
            word = struct.pack(">H", arg)
            data += list(word) + [crc8(word)]
        self.bus.i2c_rdwr(i2c_msg.write(self.addr, data))

    def _read_words(self, cmd: int, n: int) -> list[int]:
        self._cmd(cmd)
        time.sleep(0.002)
        msg = i2c_msg.read(self.addr, n * 3)
        self.bus.i2c_rdwr(msg)
        raw = bytes(msg)
        words = []
        for i in range(0, len(raw), 3):
            if crc8(raw[i:i + 2]) != raw[i + 2]:
                raise IOError("scd41 crc mismatch")
            words.append((raw[i] << 8) | raw[i + 1])
        return words

    def set_pressure(self, hpa: float) -> None:
        self._cmd(0xE000, int(round(hpa)))

    def read(self) -> dict | None:
        if self._read_words(0xE4B8, 1)[0] & 0x07FF == 0:
            return None
        co2, t, rh = self._read_words(0xEC05, 3)
        return {"co2": co2, "temp": -45 + 175 * t / 65535, "hum": 100 * rh / 65535}


class BME280:
    def __init__(self, bus: SMBus, addr: int):
        self.bus, self.addr = bus, addr
        if bus.read_byte_data(addr, 0xD0) != 0x60:
            raise IOError("not a bme280")
        c = bytes(bus.read_i2c_block_data(addr, 0x88, 26))
        self.T = struct.unpack_from("<Hhh", c, 0)
        self.P = struct.unpack_from("<Hhhhhhhhh", c, 6)
        self.H1 = c[25]
        h = bytes(bus.read_i2c_block_data(addr, 0xE1, 7))
        self.H2 = struct.unpack_from("<h", h, 0)[0]
        self.H3 = h[2]
        self.H4 = _s12((h[3] << 4) | (h[4] & 0x0F))
        self.H5 = _s12((h[5] << 4) | (h[4] >> 4))
        self.H6 = struct.unpack_from("<b", h, 6)[0]
        bus.write_byte_data(addr, 0xF2, 0x01)  # humidity x1, must precede ctrl_meas
        bus.write_byte_data(addr, 0xF5, 0xA0)  # 1 s standby
        bus.write_byte_data(addr, 0xF4, 0x27)  # temp x1, press x1, normal mode

    def read(self) -> dict:
        d = self.bus.read_i2c_block_data(self.addr, 0xF7, 8)
        adc_p = (d[0] << 12) | (d[1] << 4) | (d[2] >> 4)
        adc_t = (d[3] << 12) | (d[4] << 4) | (d[5] >> 4)
        adc_h = (d[6] << 8) | d[7]

        T1, T2, T3 = self.T
        v1 = (adc_t / 16384.0 - T1 / 1024.0) * T2
        v2 = ((adc_t / 131072.0 - T1 / 8192.0) ** 2) * T3
        t_fine = v1 + v2
        temp = t_fine / 5120.0

        P1, P2, P3, P4, P5, P6, P7, P8, P9 = self.P
        v1 = t_fine / 2.0 - 64000.0
        v2 = v1 * v1 * P6 / 32768.0 + v1 * P5 * 2.0
        v2 = v2 / 4.0 + P4 * 65536.0
        v1 = (P3 * v1 * v1 / 524288.0 + P2 * v1) / 524288.0
        v1 = (1.0 + v1 / 32768.0) * P1
        press = None
        if v1:
            p = (1048576.0 - adc_p - v2 / 4096.0) * 6250.0 / v1
            p += (P9 * p * p / 2147483648.0 + p * P8 / 32768.0 + P7) / 16.0
            press = p / 100.0

        h = t_fine - 76800.0
        h = (adc_h - (self.H4 * 64.0 + self.H5 / 16384.0 * h)) * (
            self.H2 / 65536.0 * (1.0 + self.H6 / 67108864.0 * h * (1.0 + self.H3 / 67108864.0 * h))
        )
        h *= 1.0 - self.H1 * h / 524288.0
        return {"temp": temp, "hum": min(max(h, 0.0), 100.0), "press": press}


def _s12(v: int) -> int:
    return v - 4096 if v & 0x800 else v


def post(url: str, body: bytes, headers: dict | None = None) -> None:
    req = urllib.request.Request(url, data=body, headers=headers or {}, method="POST")
    urllib.request.urlopen(req, timeout=10).close()


def write_state(state: dict | None) -> None:
    if state is None:
        try:
            os.unlink(STATE_FILE)
        except FileNotFoundError:
            pass
        return
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.chmod(tmp, 0o644)
    os.replace(tmp, STATE_FILE)


def main() -> None:
    bus = SMBus(BUS)
    scd = bme = None
    co2_alarm = False
    last_co2 = None

    while True:
        if scd is None:
            try:
                scd = SCD41(bus, SCD41_ADDR)
            except Exception as e:
                log(f"scd41 init failed: {e}")
        if bme is None:
            try:
                bme = BME280(bus, BME280_ADDR)
            except Exception as e:
                log(f"bme280 init failed: {e}")

        env = co2 = None
        if bme is not None:
            try:
                env = bme.read()
            except Exception as e:
                log(f"bme280 read failed: {e}")
                bme = None
        if scd is not None:
            try:
                if env and env["press"]:
                    scd.set_pressure(env["press"])
                co2 = scd.read()
            except Exception as e:
                log(f"scd41 read failed: {e}")
                scd = None
        if co2 is not None:
            last_co2 = co2
        elif scd is None:
            last_co2 = None

        lines = []
        state: dict = {}
        if env:
            lines += [
                f'desk_temperature_celsius{{sensor="bme280"}} {env["temp"]:.2f}',
                f'desk_humidity_percent{{sensor="bme280"}} {env["hum"]:.1f}',
            ]
            state.update(temperature_c=round(env["temp"], 1), humidity_pct=round(env["hum"], 1))
            if env["press"]:
                lines.append(f"desk_pressure_hpa {env['press']:.1f}")
                state["pressure_hpa"] = round(env["press"], 1)
        if co2:
            lines += [
                f"desk_co2_ppm {co2['co2']}",
                f'desk_temperature_celsius{{sensor="scd41"}} {co2["temp"]:.2f}',
                f'desk_humidity_percent{{sensor="scd41"}} {co2["hum"]:.1f}',
            ]
        if last_co2:
            state["co2_ppm"] = last_co2["co2"]
            # scd41 self-heats, so its climate values are only a fallback
            state.setdefault("temperature_c", round(last_co2["temp"], 1))
            state.setdefault("humidity_pct", round(last_co2["hum"], 1))

        if state:
            state["ts"] = int(time.time())
        try:
            write_state(state or None)
        except Exception as e:
            log(f"state write failed: {e}")

        if lines:
            try:
                post(VM_IMPORT, ("\n".join(lines) + "\n").encode())
            except Exception as e:
                log(f"push failed: {e}")

        if co2:
            ppm = co2["co2"]
            msg = None
            if not co2_alarm and ppm > CO2_HIGH:
                co2_alarm = True
                msg = ("CO2 high at the desk", f"{ppm} ppm, open a window", "high", "warning")
            elif co2_alarm and ppm < CO2_CLEAR:
                co2_alarm = False
                msg = ("CO2 back to normal", f"{ppm} ppm", "low", "white_check_mark")
            if msg:
                try:
                    post(NTFY_URL, msg[1].encode(), {"Title": msg[0], "Priority": msg[2], "Tags": msg[3]})
                except Exception as e:
                    log(f"ntfy post failed: {e}")

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
