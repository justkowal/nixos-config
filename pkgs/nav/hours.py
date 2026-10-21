"""A small reader for the common subset of OSM opening_hours: 'Mo-Fr 08:00-18:00; Sa 09:00-14:00; Su off', '24/7', time lists, overnight spans.
Anything outside that subset (months, weeks, sunrise, holidays logic) returns None, and the card then shows the raw text."""
import datetime
import re

DAYS = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
TIME = r"\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}"
RULE = re.compile(rf"^(?P<days>[A-Za-z][A-Za-z,\-\s]*?)?\s*(?P<times>{TIME}(?:\s*,\s*{TIME})*|off|closed)?$")


def _days(spec):
    out = set()
    for part in re.split(r"\s*,\s*", spec.strip()):
        if not part:
            continue
        m = re.fullmatch(r"([A-Z][a-z])(?:\s*-\s*([A-Z][a-z]))?", part)
        if not m or m[1] not in DAYS or (m[2] and m[2] not in DAYS):
            return None
        a = DAYS.index(m[1])
        b = DAYS.index(m[2]) if m[2] else a
        out.update(range(a, b + 1) if b >= a else list(range(a, 7)) + list(range(0, b + 1)))
    return out


def _mins(t):
    h, m = t.strip().split(":")
    return int(h) * 60 + int(m)


def parse(raw):
    """-> {weekday: [(start, end), ...]} in minutes, or None when the text is outside the supported subset."""
    raw = (raw or "").strip()
    if not raw:
        return None
    if raw == "24/7":
        return {d: [(0, 1440)] for d in range(7)}
    table = {d: [] for d in range(7)}
    for rule in re.split(r"\s*;\s*|\n", raw):
        rule = rule.strip()
        if not rule:
            continue
        if re.match(r"^(PH|SH)\b", rule):  # holiday rules: not evaluated
            continue
        m = RULE.match(rule)
        if not m or not (m["days"] or m["times"]):
            return None
        days = set(range(7))
        if m["days"]:
            days = _days(m["days"].replace("PH", "").strip(" ,"))
            if days is None:
                return None
        times = m["times"] or ""
        for d in days:
            table[d] = []  # a later rule replaces the earlier one for the same day
        if times in ("off", "closed"):
            continue
        if not times:
            return None
        for span in re.split(r"\s*,\s*", times):
            a, b = (_mins(x) for x in span.split("-"))
            for d in days:
                if b > a:
                    table[d].append((a, b))
                else:  # overnight: the rest runs into the next day
                    table[d].append((a, 1440))
                    table[(d + 1) % 7].append((0, b))
    for d in table:
        table[d] = sorted(set(table[d]))
    return table


def state(raw, now):
    """-> {"open": bool|None, "text": str, "week": [str]} for a datetime in the place's own time zone."""
    table = parse(raw)
    if table is None:
        return {"open": None, "text": "", "week": []}
    week = [f"{NAMES[d]} " + (", ".join(f"{s // 60:02d}:{s % 60:02d}-{e // 60 % 24:02d}:{e % 60:02d}" for s, e in table[d]) or "closed") for d in range(7)]
    wd, minute = now.weekday(), now.hour * 60 + now.minute
    cur = next(((s, e) for s, e in table[wd] if s <= minute < e), None)
    if cur:
        end = cur[1]
        # an interval that ends at midnight and continues after it
        if end == 1440 and any(s == 0 for s, _ in table[(wd + 1) % 7]):
            end = 1440 + max(e for s, e in table[(wd + 1) % 7] if s == 0)
        t = end % 1440
        return {"open": True, "text": "Open until " + ("24:00" if end == 1440 and not any(s == 0 for s, _ in table[(wd + 1) % 7]) else f"{t // 60:02d}:{t % 60:02d}"), "week": week}
    for add in range(8):
        d = (wd + add) % 7
        for s, _ in table[d]:
            if add > 0 or s > minute:
                when = "" if add == 0 else (" tomorrow" if add == 1 else f" {NAMES[d]}")
                return {"open": False, "text": f"Closed, opens{when} {s // 60:02d}:{s % 60:02d}", "week": week}
    return {"open": False, "text": "Closed", "week": week}
