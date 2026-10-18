#!/usr/bin/env python3
"""lab-focus-sync: keeps this machine in step with the fleet focus state on the hub.

The hub already publishes every focus change to its ntfy topic, so this follows that stream and
runs `focus apply`, which starts or ends the local side effects (pomodoro, caffeine, island, LEDs)
when focus was changed on another machine. A slow poll covers a dropped stream.
"""

import os
import subprocess
import threading
import time
import urllib.request

STREAM = os.environ.get("LAB_FOCUS_STREAM", "https://ntfy.lab/focus/json")
POLL_SECONDS = 20
lock = threading.Lock()


def apply():
    with lock:
        subprocess.run(["focus", "apply"], capture_output=True, timeout=30, check=False)


def follow():
    while True:
        try:
            # ntfy sends a keepalive line every 45 s, so a quiet socket for 2 min means it died
            with urllib.request.urlopen(STREAM, timeout=120) as resp:
                for line in resp:
                    if b'"event":"message"' in line:
                        apply()
        except (OSError, ValueError):
            pass
        time.sleep(5)


def main():
    apply()
    threading.Thread(target=follow, daemon=True).start()
    while True:
        time.sleep(POLL_SECONDS)
        apply()


if __name__ == "__main__":
    main()
