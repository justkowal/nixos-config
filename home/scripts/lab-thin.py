#!/usr/bin/env python3
"""lab-thin: the few utilities a thin client needs, as command palette entries.

  lab-thin entries        JSON for the palette: network, tailnet, audio routing, a terminal
  lab-thin wifi SSID      join a network, asking for a password in a terminal only when one is needed


Run by the palette, nothing here keeps running.
"""

import json
import re
import subprocess
import sys


def out(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=6, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def split_nmcli(line):
    """nmcli -t escapes colons inside a field with a backslash."""
    return [p.replace("\\:", ":") for p in re.split(r"(?<!\\):", line)]


def wifi_entries():
    rows, seen = [], set()
    for line in out("nmcli", "-t", "-f", "ACTIVE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "no").splitlines():
        parts = split_nmcli(line)
        if len(parts) < 4 or not parts[1] or parts[1] in seen:
            continue
        active, ssid, signal = parts[0] == "yes", parts[1], parts[2]
        seen.add(ssid)
        label = f"Wi-Fi · {ssid}  {signal}%" + ("  (connected)" if active else "")
        rows.append({"title": label, "group": "Network", "exec": f"lab-thin wifi {json.dumps(ssid)}", "rank": 2})
    return rows


def audio_entries():
    rows, section = [], None
    for line in out("wpctl", "status").splitlines():
        text = re.sub(r"^[\s│├└─]*", "", line)
        if text.endswith("Sinks:"):
            section = "output"
        elif text.endswith("Sources:"):
            section = "input"
        elif re.match(r"(Sink endpoints|Source endpoints|Streams|Filters|Clients|Devices|Video):?", text) or text.endswith(":") and not text.startswith(("*", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9")):
            section = None
        m = re.match(r"(\*?)\s*(\d+)\.\s+(.*?)\s+\[vol:", text)
        if section and m:
            active, ident, name = bool(m.group(1)), m.group(2), m.group(3)
            rows.append({"title": f"Audio {section} · {name}" + ("  (active)" if active else ""), "group": "Audio",
                         "exec": f"wpctl set-default {ident}", "rank": 1 if section == "output" else 2})
    return rows


def entries():
    rows = [
        {"title": "Network setup", "group": "Network", "exec": "foot -e nmtui", "rank": 1},
        {"title": "Tailnet status", "group": "Tailnet", "exec": "lab publish roster.show --source thin", "rank": 1},
        {"title": "Terminal", "group": "Thin client", "exec": "foot", "rank": 1},
    ]
    ssid = next((e["title"] for e in wifi_entries() if "(connected)" in e["title"]), None)
    if ssid:
        rows.insert(0, {"title": ssid.replace("Wi-Fi · ", "Connected to "), "group": "Network", "exec": "foot -e nmtui", "rank": 1})
    return rows + wifi_entries() + audio_entries()


def wifi(ssid):
    known = {name for name in out("nmcli", "-t", "-f", "NAME", "con", "show").splitlines()}
    if ssid in known:
        return subprocess.call(["nmcli", "con", "up", "id", ssid])
    secured = any(
        split_nmcli(line)[1:2] == [ssid] and split_nmcli(line)[3:4] not in (["--"], [""])
        for line in out("nmcli", "-t", "-f", "ACTIVE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "no").splitlines()
    )
    if not secured:
        return subprocess.call(["nmcli", "dev", "wifi", "connect", ssid])
    # a password is needed: nmtui asks for it in a terminal and stores the connection
    return subprocess.call(["foot", "-e", "nmtui-connect", ssid])


def main():
    args = sys.argv[1:]
    if args == ["entries"]:
        json.dump(entries(), sys.stdout)
        return 0
    if len(args) == 2 and args[0] == "wifi":
        return wifi(args[1])
    print("usage: lab-thin entries | lab-thin wifi SSID", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
