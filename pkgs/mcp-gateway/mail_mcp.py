"""Student mail MCP over IMAP and SMTP. Delete moves to Trash, send is rate limited and From is fixed."""
import html
import imaplib
import json
import os
import re
import smtplib
import threading
import time
from email import message_from_bytes, policy
from email.header import decode_header, make_header
from email.message import EmailMessage
from email.utils import formatdate, getaddresses, make_msgid, parseaddr

from stdio_mcp import obj, serve

ADDR = os.environ.get("MAIL_ADDRESS", "")
PASSWORD = os.environ.get("MAIL_PASSWORD", "")
IMAP_HOST = os.environ.get("MAIL_IMAP_HOST", "poczta.agh.edu.pl")
SMTP_HOST = os.environ.get("MAIL_SMTP_HOST", "poczta.agh.edu.pl")
LIMIT = int(os.environ.get("MAIL_SEND_LIMIT", "20"))
STATE = os.environ.get("MAIL_STATE", "/state/sends.json")
lock = threading.Lock()
HDR = "(UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)])"


def dec(v):
    return str(make_header(decode_header(v or "")))


class Imap:
    def __enter__(self):
        if not ADDR or not PASSWORD:
            raise RuntimeError("MAIL_ADDRESS or MAIL_PASSWORD is not configured")
        self.c = imaplib.IMAP4_SSL(IMAP_HOST, 993, timeout=30)
        self.c.login(ADDR, PASSWORD)
        return self.c

    def __exit__(self, *a):
        try:
            self.c.logout()
        except Exception:
            pass


def q(folder):
    if re.search(r"[\r\n]", folder):
        raise RuntimeError("bad folder name")
    return '"' + folder.replace("\\", "\\\\").replace('"', '\\"') + '"'


def select(c, folder, ro=True):
    typ, d = c.select(q(folder), readonly=ro)
    if typ != "OK":
        raise RuntimeError(f"cannot open folder {folder}")


def uid_of(a):
    u = str(a.get("uid", ""))
    if not u.isdigit():
        raise RuntimeError("uid must be a number")
    return u


def folders(c):
    out = []
    for line in c.list()[1]:
        m = re.match(rb'\((?P<f>[^)]*)\) "?(?P<s>[^" ]*)"? (?P<n>.*)', line)
        if m:
            out.append((m["n"].decode(errors="replace").strip('"'), m["f"].decode()))
    return out


def special(c, flag, fallback):
    for name, flags in folders(c):
        if flag.lower() in flags.lower():
            return name
    return fallback


def summaries(c, uids):
    if not uids:
        return []
    typ, data = c.uid("FETCH", ",".join(uids), HDR)
    out = []
    for item in data:
        if not isinstance(item, tuple):
            continue
        meta = item[0].decode(errors="replace")
        m = message_from_bytes(item[1], policy=policy.default)
        out.append({"uid": re.search(r"UID (\d+)", meta)[1],
                    "flags": (re.search(r"FLAGS \(([^)]*)\)", meta) or [0, ""])[1].split(),
                    "from": dec(m["from"]), "to": dec(m["to"]), "subject": dec(m["subject"]), "date": str(m["date"])})
    return sorted(out, key=lambda s: int(s["uid"]), reverse=True)


def t_folders(_a):
    with Imap() as c:
        return [{"name": n, "flags": f} for n, f in folders(c)]


def t_search(a):
    crit = []
    for key, field in (("from", "FROM"), ("to", "TO"), ("subject", "SUBJECT"), ("text", "TEXT")):
        if a.get(key):
            crit += [field, str(a[key]).encode()]
    if a.get("since"):
        crit += ["SINCE", time.strftime("%d-%b-%Y", time.strptime(a["since"], "%Y-%m-%d"))]
    if a.get("unseen"):
        crit.append("UNSEEN")
    with Imap() as c:
        select(c, a.get("folder", "INBOX"))
        typ, d = c.uid("SEARCH", "CHARSET", "UTF-8", *(crit or ["ALL"]))
        uids = d[0].decode().split()[-min(int(a.get("limit", 20)), 50):]
        return summaries(c, uids)


def body_of(m):
    part = m.get_body(("plain", "html"))
    if part is None:
        return ""
    text = part.get_content()
    if part.get_content_type() == "text/html":
        text = html.unescape(re.sub(r"<(script|style).*?</\1>|<[^>]+>", " ", text, flags=re.S | re.I))
    return re.sub(r"\n{3,}", "\n\n", re.sub(r"[ \t]+", " ", text)).strip()[:20000]


def fetch_full(c, uid):
    typ, d = c.uid("FETCH", uid, "(BODY.PEEK[])")
    for item in d:
        if isinstance(item, tuple):
            return message_from_bytes(item[1], policy=policy.default)
    raise RuntimeError("message not found")


def t_read(a):
    with Imap() as c:
        select(c, a.get("folder", "INBOX"))
        m = fetch_full(c, uid_of(a))
        return {"from": dec(m["from"]), "to": dec(m["to"]), "cc": dec(m["cc"]), "subject": dec(m["subject"]),
                "date": str(m["date"]), "message_id": str(m["message-id"]), "body": body_of(m),
                "attachments": [p.get_filename() for p in m.iter_attachments()]}


def t_thread(a):
    with Imap() as c:
        select(c, a.get("folder", "INBOX"))
        subj = re.sub(r"^((re|fw|fwd|odp)\s*:\s*)+", "", dec(fetch_full(c, uid_of(a))["subject"]), flags=re.I).strip()
        typ, d = c.uid("SEARCH", "CHARSET", "UTF-8", "SUBJECT", subj.encode())
        return sorted(summaries(c, d[0].decode().split()[-50:]), key=lambda s: int(s["uid"]))


def check_rate():
    with lock:
        now = time.time()
        try:
            with open(STATE) as f:
                times = [t for t in json.load(f) if t > now - 3600]
        except (OSError, ValueError):
            times = []
        if len(times) >= LIMIT:
            raise RuntimeError(f"send limit of {LIMIT} messages per hour reached")
        times.append(now)
        with open(STATE, "w") as f:
            json.dump(times, f)


def addrs(v):
    out = [x.strip() for x in (v if isinstance(v, list) else [v] if v else [])]
    if len(out) > 10 or any("@" not in x or re.search(r"[\r\n,;]", x) for x in out):
        raise RuntimeError("at most 10 valid recipient addresses")
    return out


def build(a, to, cc=None, subject=None, extra=None):
    m = EmailMessage()
    m["From"] = ADDR
    m["To"] = to
    if cc:
        m["Cc"] = cc
    m["Subject"] = subject if subject is not None else a.get("subject", "")
    m["Date"] = formatdate(localtime=True)
    m["Message-ID"] = make_msgid(domain=ADDR.split("@")[-1])
    for k, v in (extra or {}).items():
        m[k] = v
    m.set_content(a.get("body", ""))
    return m


def smtp_send(m):
    check_rate()
    with smtplib.SMTP_SSL(SMTP_HOST, 465, timeout=30) as s:
        s.login(ADDR, PASSWORD)
        s.send_message(m, from_addr=ADDR)


def t_send(a):
    to, cc = addrs(a.get("to")), addrs(a.get("cc"))
    if not to:
        raise RuntimeError("to is required")
    smtp_send(build(a, to, cc))
    return f"sent to {', '.join(to + cc)}"


def t_reply(a):
    with Imap() as c:
        select(c, a.get("folder", "INBOX"), ro=False)
        o = fetch_full(c, uid_of(a))
        to = [parseaddr(str(o["reply-to"] or o["from"]))[1]]
        cc = []
        if a.get("reply_all"):
            cc = [x for _, x in getaddresses([str(o["to"] or ""), str(o["cc"] or "")]) if x and x.lower() != ADDR.lower()]
        subj = dec(o["subject"])
        subj = subj if re.match(r"re\s*:", subj, re.I) else "Re: " + subj
        mid = str(o["message-id"] or "")
        refs = (str(o["references"] or "") + " " + mid).strip()
        smtp_send(build(a, to, cc[:9], subj, {"In-Reply-To": mid, "References": refs}))
        c.uid("STORE", uid_of(a), "+FLAGS", "\\Answered")
    return f"replied to {', '.join(to)}"


def t_draft(a):
    m = build(a, addrs(a.get("to")), addrs(a.get("cc")))
    with Imap() as c:
        drafts = special(c, "\\Drafts", "Drafts")
        typ, _ = c.append(q(drafts), "\\Draft", imaplib.Time2Internaldate(time.time()), m.as_bytes())
    return f"draft saved in {drafts}" if typ == "OK" else "draft failed"


def move(c, src, uid, dest):
    trash = special(c, "\\Trash", "Trash")
    if src == trash:
        raise RuntimeError("messages in Trash are never touched here")
    select(c, src, ro=False)
    typ, _ = c.uid("COPY", uid, q(dest))
    if typ != "OK":
        raise RuntimeError(f"copy to {dest} failed, nothing was changed")
    c.uid("STORE", uid, "+FLAGS", "\\Deleted")
    c.uid("EXPUNGE", uid)  # removes only the source copy that was just copied


def t_move(a):
    with Imap() as c:
        move(c, a.get("folder", "INBOX"), uid_of(a), a["dest"])
    return f"moved to {a['dest']}"


def t_delete(a):
    with Imap() as c:
        move(c, a.get("folder", "INBOX"), uid_of(a), special(c, "\\Trash", "Trash"))
    return "moved to Trash"


def t_flag(a):
    flag = {"seen": "\\Seen", "flagged": "\\Flagged", "answered": "\\Answered"}.get(a.get("flag"))
    if not flag:
        raise RuntimeError("flag must be seen, flagged or answered")
    with Imap() as c:
        select(c, a.get("folder", "INBOX"), ro=False)
        c.uid("STORE", uid_of(a), "+FLAGS" if a.get("value", True) else "-FLAGS", flag)
    return "ok"


F = {"folder": {"type": "string", "description": "default INBOX"}}
U = {"uid": {"type": "string"}}
MSG = {"to": {"type": "array", "items": {"type": "string"}}, "cc": {"type": "array", "items": {"type": "string"}},
       "subject": {"type": "string"}, "body": {"type": "string"}}
serve("student-email", {
    "mail_folders": dict(desc="List mail folders.", schema=obj(), fn=t_folders, ro=True),
    "mail_search": dict(desc="Search a folder (from, to, subject, text, since=YYYY-MM-DD, unseen, limit up to 50), newest first.",
                        schema=obj({**F, "from": {"type": "string"}, "to": {"type": "string"}, "subject": {"type": "string"},
                                    "text": {"type": "string"}, "since": {"type": "string"},
                                    "unseen": {"type": "boolean"}, "limit": {"type": "integer"}}), fn=t_search, ro=True),
    "mail_read": dict(desc="Read one message (headers, text body, attachment names) without marking it read.",
                      schema=obj({**F, **U}, ["uid"]), fn=t_read, ro=True),
    "mail_thread": dict(desc="Messages in a folder sharing the subject of the given one, oldest first.",
                        schema=obj({**F, **U}, ["uid"]), fn=t_thread, ro=True),
    "mail_draft": dict(desc="Save a draft in the Drafts folder.", schema=obj(MSG, ["to", "subject", "body"]), fn=t_draft),
    "mail_send": dict(desc="Send a message from the student address. Limited per hour.",
                      schema=obj(MSG, ["to", "subject", "body"]), fn=t_send, sensitive=True),
    "mail_reply": dict(desc="Reply to a message, optionally to all.",
                       schema=obj({**F, **U, "body": {"type": "string"}, "reply_all": {"type": "boolean"}}, ["uid", "body"]),
                       fn=t_reply, sensitive=True),
    "mail_move": dict(desc="Move a message to another folder.",
                      schema=obj({**F, **U, "dest": {"type": "string"}}, ["uid", "dest"]), fn=t_move),
    "mail_flag": dict(desc="Set or clear seen, flagged or answered.",
                      schema=obj({**F, **U, "flag": {"type": "string", "enum": ["seen", "flagged", "answered"]},
                                  "value": {"type": "boolean"}}, ["uid", "flag"]), fn=t_flag),
    "mail_delete": dict(desc="Move a message to Trash. Nothing is ever permanently deleted.",
                        schema=obj({**F, **U}, ["uid"]), fn=t_delete),
})
