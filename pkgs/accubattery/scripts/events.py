"""Print upcoming calendar events as JSON for the accubattery daemon.

usage: accubattery-events [HOURS]   (default 36)
Reads every enabled evolution-data-server calendar and expands recurring events into instances.
"""

import json
import sys
import time

import gi

gi.require_version("EDataServer", "1.2")
gi.require_version("ECal", "2.0")
gi.require_version("ICalGLib", "3.0")
from gi.repository import ECal, EDataServer, GLib, ICalGLib  # noqa: E402


def to_epoch(t):
    """ICalTime to unix seconds, floating times are taken as local."""
    if t is None:
        return None
    return t.as_timet_with_zone(t.get_timezone()) if t.get_timezone() else t.as_timet()


def main(hours):
    now = int(time.time())
    end = now + int(hours * 3600)
    out, seen = [], set()
    registry = EDataServer.SourceRegistry.new_sync(None)
    for source in registry.list_enabled(EDataServer.SOURCE_EXTENSION_CALENDAR):
        try:
            client = ECal.Client.connect_sync(source, ECal.ClientSourceType.EVENTS, 15, None)
        except GLib.Error as e:
            print(f"skipping {source.get_display_name()}: {e.message}", file=sys.stderr)
            continue

        def on_instance(comp, start, stop, *_):
            if comp is None or start is None:
                return True
            icomp = comp.get_icalcomponent() if hasattr(comp, "get_icalcomponent") else comp
            s, e = to_epoch(start), to_epoch(stop)
            summary = icomp.get_summary() or ""
            uid = f"{icomp.get_uid()}@{s}"
            all_day = bool(start.is_date())
            if uid not in seen and e and e > now and s < end:
                seen.add(uid)
                out.append({"uid": uid, "title": summary, "start": s, "end": e, "all_day": all_day,
                            "location": icomp.get_location() or ""})
            return True

        try:
            client.generate_instances_sync(now, end, None, on_instance, None)
        except (GLib.Error, TypeError) as err:
            print(f"instances failed for {source.get_display_name()}: {err}", file=sys.stderr)
    out.sort(key=lambda x: x["start"])
    print(json.dumps(out))


if __name__ == "__main__":
    main(float(sys.argv[1]) if len(sys.argv) > 1 else 36)
