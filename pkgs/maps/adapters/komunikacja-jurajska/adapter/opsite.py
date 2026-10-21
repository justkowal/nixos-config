"""Parser for the operator's own site (www.komunikacjajurajska.pl): line list, line pages, stop map.

A line page carries, per direction, an HTML timetable (one row per stop, one column per course,
grouped by day type), the validity period of the whole timetable, and a Leaflet script whose
L.marker(...) calls hold the stop positions and the operator's stop ids for one direction.
Pure functions on strings, no I/O.
"""
import html
import re
import unicodedata

DAY_TYPES = {"poniedziałek-piątek": "wd", "sobota": "sa", "niedziela i święta": "su",
             "poniedziałek-sobota": "wdsa", "dni robocze": "wd"}

_LINE_LINK = re.compile(r'href="/?(linia-nr-([0-9A-Za-z]+)-i(\d+)\.html)')
_VALID = re.compile(r"Rozkład na tej linii obowiązuje:\s*od\s*(\d{4}-\d\d-\d\d)\s*do\s*(\d{4}-\d\d-\d\d)")
_DIR = re.compile(r'<div id="(tam|powrot|[a-z0-9_]+)"><div class="aktu_tytul">Szczegółowy\s*<strong>wykaz kursów</strong>'
                  r'\s*na linii nr (\S+)\s*<span class="l_duze">\((.*?)\)</span>', re.S)
_TABLE = re.compile(r'<table class="no_margin rozklad">(.*?)</table>', re.S)
_ROW = re.compile(r"<tr[^>]*>(.*?)</tr>", re.S)
_CELL = re.compile(r"<(t[dh])([^>]*)>(.*?)</\1>", re.S)
_MARKER = re.compile(r"L\.marker\(\[([\d.]+),\s*([\d.]+)\],\{title:'(\d+)'.*?bindPopup\('(.*?)(?:<br/><br/>|'\))", re.S)
_TIME = re.compile(r"^(\d{1,2}):(\d\d)\s*(.*)$")
_REV = re.compile(r'href="/?(linia-nr-[0-9A-Za-z]+-i\d+\.html)[^"]*"[^>]*class="button b_odwroc"')
_LEGEND = re.compile(r'<h5>Objaśnienia:</h5>(.*?)</div>', re.S)
_SYM = re.compile(r'<span class="kolor_text">([^<]+)</span>\s*-\s*([^<]+)')
_STANOWISKO = re.compile(r"Stanowisko:\s*(\d+)")


def text(s):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", s))).strip()


def norm(name):
    """Name key used to reconcile the operator's stop names with kiedyPrzyjedzie's."""
    n = text(name).lower().replace("ł", "l")
    n = "".join(c for c in unicodedata.normalize("NFD", n) if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", " ", n).strip()


def parse_home(page):
    """[(line, relative_url)] in page order, de-duplicated."""
    seen, out = set(), []
    for url, line, _ in _LINE_LINK.findall(page):
        if url not in seen:
            seen.add(url)
            out.append((line, url))
    return out


def parse_markers(page):
    """[(order, lat, lon, operator_stop_id or None, name)] from the Leaflet script."""
    out = []
    for lat, lon, n, popup in _MARKER.findall(page):
        m = re.search(r"\[(\d+)\]\s*</span>", popup + "</span>") or re.search(r"\[(\d+)\]", popup)
        name = re.sub(r"^(START|KONIEC)", "", text(popup))
        name = re.sub(r"^\d+\.\s*", "", name)
        name = re.sub(r"\s*\[\d+\]$", "", name)
        out.append((int(n), float(lat), float(lon), int(m.group(1)) if m else None, name))
    return out


def parse_line(page):
    """Returns {"valid_from","valid_to","directions":[{"id","title","stops":[name],"courses":[...]}], "markers":[...], "problems":[...]}.

    A course is {"day": "wd"|"sa"|"su"|..., "n": course number, "times": [minutes-or-None per stop]}.
    """
    problems = []
    v = _VALID.search(text(page))
    rev = _REV.search(page)
    legend = {}
    lg = _LEGEND.search(page)
    if lg:
        legend = {text(a): text(b) for a, b in _SYM.findall(lg.group(1))}
    heads = list(_DIR.finditer(page))
    dirs = []
    for i, h in enumerate(heads):
        end = heads[i + 1].start() if i + 1 < len(heads) else len(page)
        t = _TABLE.search(page, h.end(), end)
        if not t:
            problems.append(f"direction {h.group(1)} has no table")
            continue
        rows = _ROW.findall(t.group(1))
        if len(rows) < 3:
            problems.append(f"direction {h.group(1)} table too small")
            continue
        groups, col = [], 0  # day type per course column
        for tag, attrs, inner in _CELL.findall(rows[0]):
            span = re.search(r'colspan="(\d+)"', attrs)
            if not span:
                continue
            label = text(inner).lower()
            day = DAY_TYPES.get(label)
            if day is None:
                problems.append(f"unknown day type {label!r}")
            groups += [day or label] * int(span.group(1))
        names = [int(re.sub(r"\D", "", text(c[2])) or 0) for c in _CELL.findall(rows[1])]
        if len(names) != len(groups):
            problems.append(f"direction {h.group(1)}: {len(groups)} day columns vs {len(names)} courses")
            continue
        stops, grid = [], []
        for r in rows[2:]:
            cells = _CELL.findall(r)
            if not cells:
                continue
            stops.append(re.sub(r"^\d+\.\s*", "", text(cells[0][2])))
            vals = []
            for _, _, c in cells[1:]:
                m = _TIME.match(text(c))
                if m:
                    vals.append((int(m.group(1)) * 60 + int(m.group(2)), m.group(3).strip()))
                else:
                    vals.append(None if text(c) in ("", "-", "|", "<<") else "?")
            if len(vals) != len(groups):
                problems.append(f"direction {h.group(1)} row {len(stops)}: {len(vals)} cells vs {len(groups)} courses")
                vals = (vals + [None] * len(groups))[:len(groups)]
            grid.append(vals)
        courses = []
        for j, day in enumerate(groups):
            col = [g[j] for g in grid]
            if "?" in col:
                problems.append(f"direction {h.group(1)} course {names[j]}: unreadable cell")
                col = [None if x == "?" else x for x in col]
            syms = sorted({s.strip() for x in col if x and x[1] for s in x[1].split(",") if s.strip()})
            courses.append({"day": day, "n": names[j], "times": [x[0] if x else None for x in col], "sym": syms})
        dirs.append({"id": h.group(1), "title": text(h.group(3)), "stops": stops, "courses": courses})
    return {"valid_from": v.group(1) if v else None, "valid_to": v.group(2) if v else None,
            "reverse_url": rev.group(1) if rev else None, "legend": legend,
            "directions": dirs, "markers": parse_markers(page), "problems": problems}


def _side(parsed, which, problems):
    """One direction with its stop ids and positions. Markers belong to the page's own first direction."""
    d = next((x for x in parsed["directions"] if x["id"] == which), None)
    if d is None:
        return None
    stops = [{"name": n, "id": None, "lat": None, "lon": None} for n in d["stops"]]
    mk = parsed["markers"]
    if which == "tam":
        if len(mk) == len(stops) and all(norm(m[4]) == norm(s["name"]) for m, s in zip(mk, stops)):
            for m, s in zip(mk, stops):
                s["id"], s["lat"], s["lon"] = m[3], m[1], m[2]
        else:
            problems.append(f"map markers do not line up with the timetable ({len(mk)} vs {len(stops)})")
    return {"title": d["title"], "stops": stops, "courses": d["courses"]}


def line_record(main, rev, urls, now):
    """Merge a line's main page and its reverse page. rev may be None (one-way line or not fetched)."""
    problems = list(main["problems"]) + (list(rev["problems"]) if rev else [])
    a = _side(main, "tam", problems)
    b = _side(rev, "tam", problems) if rev else None
    check = "no reverse page"
    if rev:
        other = _side(main, "powrot", [])
        same = bool(other and b and [norm(s["name"]) for s in other["stops"]] == [norm(s["name"]) for s in b["stops"]]
                    and [c["times"] for c in other["courses"]] == [c["times"] for c in b["courses"]])
        check = "ok" if same else "differs"
        if not same:
            problems.append("reverse page and the first page's return table differ")
    elif len(main["directions"]) == 1:
        check = "one-way"
    else:
        b = _side(main, "powrot", [])
        check = "return direction taken from the first page, no stop ids"
    return {"url": urls[0], "rev_url": urls[1], "fetched": now, "valid_from": main["valid_from"],
            "valid_to": main["valid_to"], "legend": {**(rev["legend"] if rev else {}), **main["legend"]},
            "dirs": {k: v for k, v in (("A", a), ("B", b)) if v}, "crosscheck": check, "problems": problems}
