#!/usr/bin/env python3
"""Poll a Shelly Gen3 plug and push power, energy and the current tariff price to VictoriaMetrics."""

import json
import os
import sys
import time
import urllib.request

SHELLY = os.environ["SHELLY_HOST"]
DEVICE = os.environ.get("DEVICE_NAME", "desktop")
VM_IMPORT = os.environ.get("VM_IMPORT_URL", "http://127.0.0.1:8428/api/v1/import/prometheus")
INTERVAL = float(os.environ.get("INTERVAL_S", "15"))
TARIFF = json.loads(os.environ["TARIFF_JSON"])


def _minutes(hhmm: str) -> int:
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)


def is_off_peak(now: time.struct_time) -> bool:
    t = now.tm_hour * 60 + now.tm_min
    for w in TARIFF["offPeakWindows"]:
        s, e = _minutes(w["start"]), _minutes(w["end"])
        if (s <= t < e) if s <= e else (t >= s or t < e):
            return True
    return False


def get_status() -> dict:
    url = f"http://{SHELLY}/rpc/Switch.GetStatus?id=0"
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.load(r)


def push(lines: list[str]) -> None:
    req = urllib.request.Request(VM_IMPORT, data=("\n".join(lines) + "\n").encode(), method="POST")
    urllib.request.urlopen(req, timeout=10).close()


def main() -> None:
    while True:
        off_peak = is_off_peak(time.localtime())
        price = TARIFF["priceOffPeak"] if off_peak else TARIFF["pricePeak"]
        lines = [
            f'electricity_price_pln_per_kwh{{tariff="{TARIFF["name"]}"}} {price}',
        ]
        try:
            st = get_status()
            lines += [
                f'shelly_apower_watts{{device="{DEVICE}"}} {st["apower"]}',
                f'shelly_aenergy_wh_total{{device="{DEVICE}"}} {st["aenergy"]["total"]}',
                f'shelly_up{{device="{DEVICE}"}} 1',
            ]
        except Exception as e:
            print(f"shelly poll failed: {e}", file=sys.stderr, flush=True)
            lines.append(f'shelly_up{{device="{DEVICE}"}} 0')
        try:
            push(lines)
        except Exception as e:
            print(f"push failed: {e}", file=sys.stderr, flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
