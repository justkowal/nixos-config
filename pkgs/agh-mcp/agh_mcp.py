#!/usr/bin/env python3
"""agh-mcp: read-only MCP server for AGH study data over stdio.

UPeL (Moodle) goes through the REST API with the personal web service token the mobile app uses.
Syllabi come from the public sylabusy.agh.edu.pl, scoped to one programme (default: Computer
Physics, first cycle, intake 2025/2026). Override the programme with AGH_SYLLABUS_* variables.

  agh-mcp                 run the server
  agh-mcp callback URL    write the token from a moodlemobile://token=... redirect (desktop handler)
"""

import base64
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from html.parser import HTMLParser

UPEL = os.environ.get("UPEL_URL", "https://upel.agh.edu.pl")
TOKEN_FILE = os.environ.get("UPEL_TOKEN_FILE", os.path.expanduser("~/.config/upel/token"))
LOGIN_TIMEOUT = 600
LOGIN_SCHEME = "moodlemobile"

SYLLABUS = os.environ.get("AGH_SYLLABUS_URL", "https://sylabusy.agh.edu.pl")
LANG = os.environ.get("AGH_SYLLABUS_LANG", "en")
# ids come from the site's own links: /en/1/2/{year}/{form}/{level}/{faculty}/{major}
PROGRAMME = {
    "year": os.environ.get("AGH_SYLLABUS_YEAR", "21"),  # 21 = intake 2025/2026
    "form": os.environ.get("AGH_SYLLABUS_FORM", "1"),  # 1 full-time, 2 part-time
    "level": os.environ.get("AGH_SYLLABUS_LEVEL", "4"),  # 4 first-cycle engineer, 5 second-cycle
    "faculty": os.environ.get("AGH_SYLLABUS_FACULTY", "17"),  # Physics and Applied Computer Science
    "major": os.environ.get("AGH_SYLLABUS_MAJOR", "236"),  # Computer Physics
}


class NotAuthorized(Exception):
    pass


def read_token_file():
    try:
        with open(TOKEN_FILE) as f:
            return f.read().strip() or None
    except OSError:
        return None


def load_token():
    return os.environ.get("UPEL_TOKEN", "").strip() or read_token_file()


def moodle(fn, params=None, token=None):
    token = token or load_token()
    if not token:
        raise NotAuthorized("not signed in to UPeL")
    body = urllib.parse.urlencode(
        {"wstoken": token, "wsfunction": fn, "moodlewsrestformat": "json", **(params or {})}
    ).encode()
    with urllib.request.urlopen(f"{UPEL}/webservice/rest/server.php", body, timeout=30) as r:
        data = json.load(r)
    if isinstance(data, dict) and data.get("exception"):
        if data.get("errorcode") == "invalidtoken":
            raise NotAuthorized(data.get("message", "invalid token"))
        raise RuntimeError(f"{data.get('errorcode')}: {data.get('message')}")
    return data


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts)) if ts else None


# same flow as the Moodle mobile app: browser signs in through AGH SSO, Moodle redirects to
# moodlemobile://token=..., the desktop handler runs `agh-mcp callback`, the watcher verifies it
_login_lock = threading.Lock()
_login_url = None


def start_login():
    global _login_url
    with _login_lock:
        if _login_url:
            return None
        passport = uuid.uuid4().hex
        _login_url = (
            f"{UPEL}/admin/tool/mobile/launch.php?service=moodle_mobile_app"
            f"&passport={passport}&urlscheme={LOGIN_SCHEME}"
        )
        url = _login_url
    sys.stderr.write(f"agh: sign in at {url}\n")
    try:
        subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass
    threading.Thread(target=_watch_for_token, daemon=True).start()
    return url


def _watch_for_token():
    global _login_url
    deadline = time.time() + LOGIN_TIMEOUT
    tried = None
    while time.time() < deadline:
        time.sleep(2)
        candidate = read_token_file()
        if not candidate or candidate == tried:
            continue
        tried = candidate
        try:
            info = moodle("core_webservice_get_site_info", token=candidate)
            sys.stderr.write(f"agh: signed in as {info['username']}\n")
            break
        except (NotAuthorized, RuntimeError, OSError) as e:
            sys.stderr.write(f"agh: token from callback rejected: {e}\n")
    with _login_lock:
        _login_url = None


def ensure_authorized():
    try:
        moodle("core_webservice_get_site_info")
    except NotAuthorized:
        start_login()
    except (RuntimeError, OSError):
        pass


def write_token_from_callback(url):
    m = re.search(r"token=([^&\s]+)", url)
    if not m:
        return 1
    payload = urllib.parse.unquote(m.group(1)).replace("-", "+").replace("_", "/")
    payload += "=" * (-len(payload) % 4)
    decoded = base64.b64decode(payload).decode("utf8", "replace")
    # signature:::token[:::privatetoken], the web service token is field 1
    parts = re.split(r":{3}", decoded)
    token = parts[1].strip() if len(parts) > 1 else ""
    if not token:
        return 1
    os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token)
    return 0


_user_id = None


def user_id():
    global _user_id
    if _user_id is None:
        _user_id = moodle("core_webservice_get_site_info")["userid"]
    return _user_id


def t_whoami(_a):
    i = moodle("core_webservice_get_site_info")
    return {"fullname": i["fullname"], "username": i["username"], "site": i["sitename"]}


def t_list_courses(_a):
    cs = moodle("core_enrol_get_users_courses", {"userid": user_id()})
    return [{"id": c["id"], "shortname": c["shortname"], "fullname": c["fullname"], "visible": c.get("visible")} for c in cs]


def t_upcoming_events(a):
    d = moodle(
        "core_calendar_get_action_events_by_timesort",
        {"limitnum": str(a.get("limit", 20)), "timesortfrom": str(int(time.time())), "limittononsuspendedevents": "1"},
    )
    return [
        {"name": e["name"], "course": (e.get("course") or {}).get("fullname"), "due": iso(e["timesort"]), "url": e.get("url")}
        for e in d.get("events", [])
    ]


def t_course_contents(a):
    secs = moodle("core_course_get_contents", {"courseid": str(a["courseid"])})
    return [
        {"section": s["name"], "activities": [{"type": m["modname"], "name": m["name"], "url": m.get("url")} for m in s.get("modules", [])]}
        for s in secs
    ]


def t_assignments(a):
    ids = [a["courseid"]] if a.get("courseid") else [c["id"] for c in t_list_courses({})]
    if not ids:
        return []
    d = moodle("mod_assign_get_assignments", {f"courseids[{i}]": str(c) for i, c in enumerate(ids)})
    return [
        {
            "course": c["fullname"],
            "name": x["name"],
            "due": iso(x.get("duedate")),
            "cutoff": iso(x.get("cutoffdate")),
            "submitted": x.get("submissionstatus"),
            "cmid": x.get("cmid"),
        }
        for c in d.get("courses", [])
        for x in c["assignments"]
    ]


def t_course_grades(_a):
    d = moodle("gradereport_overview_get_course_grades", {"userid": user_id()})
    return [{"courseid": g["courseid"], "grade": g.get("grade"), "rawgrade": g.get("rawgrade")} for g in d.get("grades", [])]


def t_notifications(a):
    d = moodle(
        "message_popup_get_popup_notifications",
        {"useridto": str(user_id()), "newestfirst": "1", "limit": str(a.get("limit", 20))},
    )
    return [
        {"subject": n["subject"], "read": n.get("timeread") is not None, "time": iso(n.get("timecreated")), "url": n.get("contexturl")}
        for n in d.get("notifications", [])
    ]


def fetch(path):
    req = urllib.request.Request(SYLLABUS + path, headers={"User-Agent": "agh-mcp"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf8", "replace")


def squash(s):
    return re.sub(r"\s+", " ", s).strip(" ;")


class ProgrammePage(HTMLParser):
    """Pulls the subject table of each semester tab out of a programme page."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title = ""
        self.subtitle = ""
        self.tabs = {}  # tab id -> "Semester 3"
        self.rows = []
        self._panel = None
        self._grab = None  # what the next text belongs to
        self._buf = ""
        self._cells = None
        self._cell = None
        self._sub = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "h1" and a.get("id") == "syl-major-name":
            self._start("title")
        elif tag == "div" and a.get("role") == "doc-subtitle":
            self._start("subtitle")
        elif tag == "button" and re.fullmatch(r"nav-tab-\d+", a.get("id") or ""):
            self._start("tab", a["id"][len("nav-tab-"):])
        elif tag == "div" and re.fullmatch(r"nav-tab-\w+-panel", a.get("id") or ""):
            self._panel = a["id"][len("nav-tab-"):-len("-panel")]
        elif tag == "tr":
            self._cells, self._sub = [], None
        elif tag == "td" and self._cells is not None:
            self._cell = ""
        elif tag == "button" and a.get("data-syllabus-id") and self._cells is not None:
            self._sub = {"id": a["data-syllabus-id"], "name": ""}
            self._grab = "subject"
        elif tag == "br" and self._cell is not None:
            self._cell += "; "

    def _start(self, what, key=None):
        self._grab, self._buf, self._key = what, "", key

    def handle_data(self, data):
        if self._cell is not None:
            self._cell += data
        if self._grab == "subject":
            self._sub["name"] += data
        elif self._grab:
            self._buf += data

    def handle_endtag(self, tag):
        if tag in ("h1", "div", "button") and self._grab:
            if self._grab == "title" and tag == "h1":
                self.title = squash(self._buf).removeprefix("Major ")
            elif self._grab == "subtitle" and tag == "div":
                self.subtitle = squash(self._buf)
            elif self._grab == "tab" and tag == "button":
                self.tabs[self._key] = squash(self._buf)
            elif self._grab == "subject" and tag == "button":
                self._sub["name"] = squash(self._sub["name"])
            else:
                return
            self._grab = None
        elif tag == "td" and self._cell is not None:
            self._cells.append(squash(self._cell))
            self._cell = None
        elif tag == "tr" and self._sub and self._cells is not None:
            c = self._cells[1:5] + [""] * 4
            self.rows.append(
                {"semester": self._panel, "id": self._sub["id"], "name": self._sub["name"],
                 "hours": c[0], "ects": c[1], "verification": c[2], "mandatoriness": c[3]}
            )
            self._cells = self._sub = None


class DocumentText(HTMLParser):
    """Syllabus HTML to readable text. Cells of a row are joined with ' | '."""

    BLOCK = {"p", "div", "tr", "li", "ul", "table", "h1", "h2", "h3", "h4", "h5", "h6", "br", "dl", "dt", "dd"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip += 1
        elif tag in self.BLOCK:
            self.out.append("\n")
        elif tag in ("td", "th"):
            self.out.append(" | ")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip -= 1
        elif tag in self.BLOCK:
            self.out.append("\n")

    def handle_data(self, data):
        if not self._skip:
            self.out.append(data)

    def text(self):
        lines = (squash(re.sub(r"\s+", " ", ln)).strip("| ").strip() for ln in "".join(self.out).split("\n"))
        return "\n".join(ln for ln in lines if ln)


def programme_path():
    p = PROGRAMME
    return f"/{LANG}/1/2/{p['year']}/{p['form']}/{p['level']}/{p['faculty']}/{p['major']}"


_programme_cache = None


def programme():
    global _programme_cache
    if _programme_cache is None:
        page = ProgrammePage()
        page.feed(fetch(programme_path()))
        for r in page.rows:
            r["semester"] = page.tabs.get(r["semester"], r["semester"])
        _programme_cache = {"programme": page.title, "intake": page.subtitle, "path": programme_path(), "subjects": page.rows}
    return _programme_cache


def t_syllabus_subjects(a):
    prog = programme()
    wanted = (a.get("semester") or "").strip().lower()
    subjects = [s for s in prog["subjects"] if not wanted or wanted in s["semester"].lower()]
    return {**prog, "subjects": subjects}


def t_syllabus_subject(a):
    q = a["subject"].strip()
    if re.fullmatch(r"[0-9a-fA-F-]{36}", q):
        sid = q
    else:
        hits = [s for s in programme()["subjects"] if q.lower() in s["name"].lower()]
        if not hits:
            raise RuntimeError(f"no subject matching {q!r} in {programme()['programme']}, try syllabus_subjects")
        if len({h["id"] for h in hits}) > 1:
            names = ", ".join(f"{h['name']} ({h['semester']})" for h in hits)
            raise RuntimeError(f"{q!r} is ambiguous: {names}")
        sid = hits[0]["id"]
    html = fetch(f"/{LANG}/document/{sid}.html?partialType=modal")
    p = DocumentText()
    p.feed(html)
    return p.text()


def obj(props=None, required=None):
    return {"type": "object", "properties": props or {}, **({"required": required} if required else {})}


LIMIT = {"limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 20}}
TOOLS = {
    "whoami": ("Show the UPeL account this token belongs to.", obj(), t_whoami),
    "list_courses": ("List the courses you are enrolled in on UPeL.", obj(), t_list_courses),
    "upcoming_events": ("List upcoming calendar events and deadlines from now on.", obj(LIMIT), t_upcoming_events),
    "course_contents": (
        "List sections and activities (files, pages, links) of one course.",
        obj({"courseid": {"type": "integer"}}, ["courseid"]),
        t_course_contents,
    ),
    "assignments": (
        "List assignments with due dates, for one course or all enrolled courses.",
        obj({"courseid": {"type": "integer", "description": "omit for all courses"}}),
        t_assignments,
    ),
    "course_grades": ("Show your current grade in each enrolled course.", obj(), t_course_grades),
    "notifications": ("Show recent Moodle notifications (grades, forum replies, messages) for you.", obj(LIMIT), t_notifications),
    "syllabus_subjects": (
        "List the subjects of the configured AGH programme (default Computer Physics, intake 2025/2026) "
        "with semester, hours, ECTS, form of verification and syllabus id.",
        obj({"semester": {"type": "string", "description": "filter, e.g. 'Semester 3'"}}),
        t_syllabus_subjects,
    ),
    "syllabus_subject": (
        "Full course description sheet for one subject of the configured programme: coordinator, "
        "lecturers, goals, learning outcomes, verification methods, content, literature. "
        "Takes a name fragment or a syllabus id from syllabus_subjects.",
        obj({"subject": {"type": "string"}}, ["subject"]),
        t_syllabus_subject,
    ),
}


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def result(id_, res):
    send({"jsonrpc": "2.0", "id": id_, "result": res})


def error(id_, code, message):
    send({"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": message}})


def tool_text(text, is_error=False):
    out = {"content": [{"type": "text", "text": text}]}
    return {**out, "isError": True} if is_error else out


def call_tool(name, args):
    desc_schema_fn = TOOLS.get(name)
    if desc_schema_fn is None:
        raise KeyError(name)
    try:
        out = desc_schema_fn[2](args)
    except NotAuthorized:
        url = start_login()
        hint = f"Sign in at {url}" if url else "Opened the UPeL login page. Finish signing in, then retry."
        return tool_text(f"Not signed in. {hint}", True)
    except (RuntimeError, OSError, urllib.error.URLError, KeyError) as e:
        return tool_text(str(e) or type(e).__name__, True)
    return tool_text(out if isinstance(out, str) else json.dumps(out, indent=2, ensure_ascii=False))


def handle(msg):
    id_, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
    if id_ is None:
        return
    if method == "initialize":
        result(id_, {
            "protocolVersion": params.get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "agh", "version": "0.2.0"},
        })
    elif method == "tools/list":
        result(id_, {"tools": [
            {"name": n, "description": d, "inputSchema": s, "annotations": {"readOnlyHint": True}}
            for n, (d, s, _) in TOOLS.items()
        ]})
    elif method == "tools/call":
        try:
            result(id_, call_tool(params.get("name"), params.get("arguments") or {}))
        except KeyError:
            error(id_, -32602, f"unknown tool: {params.get('name')}")
    elif method == "ping":
        result(id_, {})
    else:
        error(id_, -32601, f"method not found: {method}")


def serve():
    threading.Thread(target=ensure_authorized, daemon=True).start()
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            error(None, -32700, "parse error")
            continue
        try:
            handle(msg)
        except Exception as e:  # keep the stdio loop alive
            error(msg.get("id"), -32603, str(e))


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "callback":
        return write_token_from_callback(sys.argv[2] if len(sys.argv) > 2 else "")
    serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
