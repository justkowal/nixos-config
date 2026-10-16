"""Print 'travel' if tomorrow's calendar has a matching event, else 'home'.

Usage: battery-schedule-calendar KEYWORD...
Matches (case-insensitive substring) against event summary, categories and location
of every enabled evolution-data-server calendar.
"""

import datetime as dt
import sys

import gi

gi.require_version("EDataServer", "1.2")
gi.require_version("ECal", "2.0")
from gi.repository import ECal, EDataServer, GLib  # noqa: E402


def utc_stamp(t):
    return t.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def tomorrow_sexp():
    now = dt.datetime.now().astimezone()
    start = (now + dt.timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + dt.timedelta(days=1)
    return f'(occur-in-time-range? (make-time "{utc_stamp(start)}") (make-time "{utc_stamp(end)}"))'


def event_texts(comp):
    texts = []
    summary = comp.get_summary()
    if summary is not None and summary.get_value():
        texts.append(summary.get_value())
    texts += comp.get_categories_list() or []
    location = comp.get_location()
    if location:
        texts.append(location)
    return texts


def main(keywords):
    keywords = [k.lower() for k in keywords if k]
    registry = EDataServer.SourceRegistry.new_sync(None)
    sexp = tomorrow_sexp()
    for source in registry.list_enabled(EDataServer.SOURCE_EXTENSION_CALENDAR):
        try:
            client = ECal.Client.connect_sync(source, ECal.ClientSourceType.EVENTS, 15, None)
            res = client.get_object_list_as_comps_sync(sexp, None)
        except GLib.Error as e:
            print(f"skipping {source.get_display_name()}: {e.message}", file=sys.stderr)
            continue
        comps = res[1] if isinstance(res, tuple) else res
        for comp in comps or []:
            for text in event_texts(comp):
                if any(k in text.lower() for k in keywords):
                    print(f"match in {source.get_display_name()}: {text}", file=sys.stderr)
                    print("travel")
                    return
    print("home")


if __name__ == "__main__":
    main(sys.argv[1:])
