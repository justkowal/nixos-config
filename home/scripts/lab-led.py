#!/usr/bin/env python3
"""lab-led: the LED layer. Loads OpenRGB profiles when bus events say the desk state changed."""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab_bus  # noqa: E402


def profile_for(ev, mapping):
    """`name:payload-name` (scene.done:leave) wins over plain `name` (focus.on)."""
    sub = (ev.get("payload") or {}).get("name")
    return mapping.get(f"{ev['name']}:{sub}") or mapping.get(ev["name"])


def load_profile(profile):
    from openrgb import OpenRGBClient

    OpenRGBClient(name="lab").load_profile(profile)


def main(path):
    with open(path) as f:
        mapping = json.load(f)
    while True:
        try:
            for ev in lab_bus.watch():
                profile = profile_for(ev, mapping)
                if not profile:
                    continue
                try:
                    load_profile(profile)
                except Exception as e:  # a missing server or profile must not kill the layer
                    print(f"lab-led: {profile}: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
        except OSError:
            pass  # bus not up yet or restarting
        time.sleep(2)


if __name__ == "__main__":
    main(sys.argv[1])
