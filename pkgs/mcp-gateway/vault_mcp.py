"""Notes vault MCP over plain Markdown files. Confined to one root, atomic writes, trash instead of delete.

Run `vault_mcp.py purge-trash [days]` by hand to empty .trash. Nothing else ever removes a file.
"""
import json
import os
import re
import sys
import threading
import time

import yaml

from stdio_mcp import obj, serve

ROOT = os.path.realpath(os.environ.get("VAULT_DIR", "/vault"))
WRITABLE = [p.strip("/ ") for p in os.environ.get("VAULT_WRITABLE", "").split(",") if p.strip("/ ")]  # empty = whole vault
MAX_BYTES = int(os.environ.get("VAULT_MAX_NOTE_BYTES", "262144"))
MAX_MULTI = int(os.environ.get("VAULT_MAX_MULTI", "10"))
STATUS = os.environ.get("VAULT_STATUS_FILE", "/tmp/vault_status.json")
HIDDEN = {".obsidian", ".git", ".stfolder", ".stversions", ".stignore", ".trash", ".history"}
FM = re.compile(r"\A---\n(.*?\n)---\n?", re.S)
TAG = re.compile(r"(?<![\w/#])#([A-Za-z][\w/-]*)")


def resolve(rel, must_exist=False, write=False):
    if not isinstance(rel, str) or "\x00" in rel or os.path.isabs(rel):
        raise RuntimeError("path must be relative to the vault")
    parts = [p for p in rel.replace("\\", "/").split("/") if p not in ("", ".")]
    if ".." in parts or any(p in HIDDEN for p in parts):
        raise RuntimeError("path not allowed")
    cur = ROOT
    for p in parts:
        cur = os.path.join(cur, p)
        if os.path.islink(cur):
            raise RuntimeError("symlinks are not followed")
    real = os.path.realpath(cur)
    if real != ROOT and not real.startswith(ROOT + os.sep):
        raise RuntimeError("path escapes the vault")
    if write and WRITABLE and not any(rel_of(real) == w or rel_of(real).startswith(w + "/") for w in WRITABLE):
        raise RuntimeError(f"writes are limited to: {', '.join(WRITABLE)}")
    if must_exist and not os.path.exists(real):
        raise RuntimeError("not found")
    return real


def rel_of(p):
    return os.path.relpath(p, ROOT).replace(os.sep, "/")


def note_path(rel, **kw):
    p = resolve(rel, **kw)
    if not p.endswith(".md"):
        raise RuntimeError("notes must end in .md")
    return p


def read_text(p):
    if os.path.getsize(p) > MAX_BYTES:
        raise RuntimeError(f"note larger than {MAX_BYTES} bytes")
    with open(p, encoding="utf-8") as f:
        return f.read()


def snapshot(p):
    """keep the previous version in .history before it is replaced."""
    if not os.path.isfile(p):
        return
    d = os.path.join(ROOT, ".history", os.path.dirname(rel_of(p)))
    os.makedirs(d, exist_ok=True)
    with open(p, "rb") as src, open(os.path.join(d, f"{os.path.basename(p)}.{time.strftime('%Y%m%dT%H%M%S')}"), "wb") as dst:
        dst.write(src.read())


def atomic_write(p, text):
    if len(text.encode()) > MAX_BYTES:
        raise RuntimeError(f"content larger than {MAX_BYTES} bytes")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = os.path.join(os.path.dirname(p), f".{os.path.basename(p)}.{os.getpid()}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, p)


def split_fm(text):
    m = FM.match(text)
    if not m:
        return {}, text
    try:
        data = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError:
        raise RuntimeError("frontmatter is not valid YAML")
    return (data if isinstance(data, dict) else {}), text[m.end():]


def join_fm(fm, body):
    return ("---\n" + yaml.safe_dump(fm, sort_keys=False, allow_unicode=True) + "---\n" + body) if fm else body


def walk(sub=""):
    base = resolve(sub)
    for dp, dn, fn in os.walk(base):
        dn[:] = [d for d in dn if d not in HIDDEN and not os.path.islink(os.path.join(dp, d))]
        for f in fn:
            p = os.path.join(dp, f)
            if not os.path.islink(p):
                yield p


def notes(sub=""):
    return [p for p in walk(sub) if p.endswith(".md") and ".sync-conflict-" not in p]


def conflicts():
    return sorted(rel_of(p) for p in walk() if ".sync-conflict-" in p)


def info(p):
    st = os.stat(p)
    return {"path": rel_of(p), "bytes": st.st_size, "mtime": st.st_mtime}


# ---- read tools
def t_read_note(a):
    p = note_path(a.get("path"), must_exist=True)
    return {**info(p), "content": read_text(p)}


def t_read_multiple(a):
    paths = a.get("paths") or []
    if len(paths) > MAX_MULTI:
        raise RuntimeError(f"at most {MAX_MULTI} notes per call")
    return [t_read_note({"path": x}) for x in paths]


def t_lines(a):
    p = note_path(a.get("path"), must_exist=True)
    lines = read_text(p).split("\n")
    s, e = max(int(a.get("start", 1)), 1), int(a.get("end", len(lines)))
    return {"path": rel_of(p), "start": s, "text": "\n".join(lines[s - 1:e])}


def t_outline(a):
    p = note_path(a.get("path"), must_exist=True)
    return [{"line": i + 1, "level": len(m.group(1)), "title": m.group(2).strip()}
            for i, l in enumerate(read_text(p).split("\n")) if (m := re.match(r"(#{1,6})\s+(.*)", l))]


def t_info(a):
    return [info(note_path(x, must_exist=True)) for x in (a.get("paths") or [])[:MAX_MULTI * 5]]


def t_get_fm(a):
    return split_fm(read_text(note_path(a.get("path"), must_exist=True)))[0]


def t_search(a):
    q = str(a.get("query", "")).lower()
    if not q:
        raise RuntimeError("query is required")
    out = []
    for p in notes(a.get("folder", "")):
        try:
            text = read_text(p)
        except RuntimeError:
            continue
        for i, l in enumerate(text.split("\n")):
            if q in l.lower() or q in rel_of(p).lower():
                out.append({"path": rel_of(p), "line": i + 1, "snippet": l.strip()[:160]})
                break
        if len(out) >= int(a.get("limit", 20)):
            break
    return out


def t_list(a):
    p = resolve(a.get("path", ""), must_exist=True)
    return sorted(({"name": n, "type": "dir" if os.path.isdir(os.path.join(p, n)) else "file"}
                   for n in os.listdir(p) if n not in HIDDEN and not os.path.islink(os.path.join(p, n))),
                  key=lambda e: (e["type"], e["name"]))


def all_tags():
    tags = {}
    for p in notes():
        try:
            fm, body = split_fm(read_text(p))
        except RuntimeError:
            continue
        found = set(TAG.findall(body)) | {str(t).lstrip("#") for t in (fm.get("tags") or []) if isinstance(fm.get("tags"), list)}
        for t in found:
            tags[t] = tags.get(t, 0) + 1
    return tags


def t_wiki(a):
    name = str(a.get("name", "")).strip().lower()
    hits = [rel_of(p) for p in notes() if os.path.basename(p)[:-3].lower() == name]
    back = []
    for p in notes():
        try:
            if re.search(r"\[\[" + re.escape(str(a.get("name", ""))) + r"(\||#|\]\])", read_text(p), re.I):
                back.append(rel_of(p))
        except RuntimeError:
            pass
    return {"matches": hits, "backlinks": back[:50]}


def t_stats(_a):
    ns = notes()
    trash = os.path.join(ROOT, ".trash")
    return {"notes": len(ns), "bytes": sum(os.path.getsize(p) for p in ns), "tags": len(all_tags()),
            "trash_items": len(os.listdir(trash)) if os.path.isdir(trash) else 0, "sync_conflicts": len(conflicts()),
            "write_scope": WRITABLE or "full vault"}


# ---- write tools
def t_write(a):
    p = note_path(a.get("path"), write=True)
    if os.path.exists(p) and a.get("overwrite") is not True:
        raise RuntimeError("note exists, pass overwrite=true to replace it (previous version goes to .history)")
    snapshot(p)
    atomic_write(p, str(a.get("content", "")))
    return {"written": rel_of(p), **{k: v for k, v in info(p).items() if k != "path"}}


def t_patch(a):
    p = note_path(a.get("path"), must_exist=True, write=True)
    old, new = a.get("old"), a.get("new")
    if not isinstance(old, str) or not old or not isinstance(new, str):
        raise RuntimeError("old (non-empty) and new are required")
    if a.get("expected_mtime") is not None and abs(os.stat(p).st_mtime - float(a["expected_mtime"])) > 0.001:
        raise RuntimeError("stale: the note changed since you read it, read it again")
    text = read_text(p)
    n = text.count(old)
    if n == 0:
        raise RuntimeError("stale: expected text not found, the note changed or old is wrong")
    if n > 1 and a.get("replace_all") is not True:
        raise RuntimeError(f"old text occurs {n} times, make it unique or pass replace_all=true")
    snapshot(p)
    atomic_write(p, text.replace(old, new))
    return {"patched": rel_of(p), "replacements": n if a.get("replace_all") else 1}


def t_update_fm(a):
    p = note_path(a.get("path"), must_exist=True, write=True)
    fm, body = split_fm(read_text(p))
    fm.update(a.get("set") or {})
    for k in a.get("remove") or []:
        fm.pop(k, None)
    snapshot(p)
    atomic_write(p, join_fm(fm, body))
    return {"updated": rel_of(p), "keys": list(fm)}


def t_tags(a):
    p = note_path(a.get("path"), must_exist=True, write=True)
    fm, body = split_fm(read_text(p))
    cur = [str(t) for t in (fm.get("tags") or [])] if isinstance(fm.get("tags"), list) else []
    cur = [t for t in cur if t not in (a.get("remove") or [])] + [t for t in (a.get("add") or []) if t not in cur]
    fm["tags"] = cur
    snapshot(p)
    atomic_write(p, join_fm(fm, body))
    return {"path": rel_of(p), "tags": cur}


# ---- destructive tools
def move(a, notes_only):
    src = (note_path if notes_only else resolve)(a.get("path"), must_exist=True, write=True)
    dst = (note_path if notes_only else resolve)(a.get("new_path"), write=True)
    if os.path.exists(dst):
        raise RuntimeError("destination exists, nothing was moved")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    os.rename(src, dst)
    return {"moved": rel_of(src), "to": rel_of(dst)}


def t_delete(a):
    p = note_path(a.get("path"), must_exist=True, write=True)
    dst = os.path.join(ROOT, ".trash", time.strftime("%Y%m%dT%H%M%S") + "__" + rel_of(p).replace("/", "__"))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    os.rename(p, dst)
    return {"trashed": rel_of(p), "to": rel_of(dst)}


def purge(days):
    trash, n = os.path.join(ROOT, ".trash"), 0
    for f in os.listdir(trash) if os.path.isdir(trash) else []:
        fp = os.path.join(trash, f)
        if time.time() - os.path.getmtime(fp) >= days * 86400:
            os.remove(fp)
            n += 1
    print(f"purged {n} item(s)")


P = {"path": {"type": "string", "description": "relative to the vault root"}}
TOOLS = {
    "read_note": dict(desc="Read a note with its size and mtime.", schema=obj(P, ["path"]), fn=t_read_note, ro=True, **{"class": "read"}),
    "read_multiple_notes": dict(desc=f"Read up to {MAX_MULTI} notes.", schema=obj({"paths": {"type": "array", "items": {"type": "string"}}}, ["paths"]), fn=t_read_multiple, ro=True, **{"class": "read"}),
    "read_note_lines": dict(desc="Read a line range of a note.", schema=obj({**P, "start": {"type": "integer"}, "end": {"type": "integer"}}, ["path"]), fn=t_lines, ro=True, **{"class": "read"}),
    "get_note_outline": dict(desc="Headings of a note.", schema=obj(P, ["path"]), fn=t_outline, ro=True, **{"class": "read"}),
    "get_notes_info": dict(desc="Size and mtime of notes.", schema=obj({"paths": {"type": "array", "items": {"type": "string"}}}, ["paths"]), fn=t_info, ro=True, **{"class": "read"}),
    "get_frontmatter": dict(desc="YAML frontmatter of a note.", schema=obj(P, ["path"]), fn=t_get_fm, ro=True, **{"class": "read"}),
    "search_notes": dict(desc="Case-insensitive search over note text and paths.", schema=obj({"query": {"type": "string"}, "folder": {"type": "string"}, "limit": {"type": "integer"}}, ["query"]), fn=t_search, ro=True, **{"class": "read"}),
    "list_directory": dict(desc="List a vault folder.", schema=obj({"path": {"type": "string"}}), fn=t_list, ro=True, **{"class": "read"}),
    "list_all_tags": dict(desc="Every tag with its note count.", schema=obj(), fn=lambda a: all_tags(), ro=True, **{"class": "read"}),
    "wiki_link": dict(desc="Resolve a [[wikilink]] name to notes and list backlinks. Read-only.", schema=obj({"name": {"type": "string"}}, ["name"]), fn=t_wiki, ro=True, **{"class": "read"}),
    "get_vault_stats": dict(desc="Counts, trash size, sync conflicts and the active write scope.", schema=obj(), fn=t_stats, ro=True, **{"class": "read"}),
    "list_sync_conflicts": dict(desc="Syncthing conflict files. Never resolved automatically.", schema=obj(), fn=lambda a: conflicts(), ro=True, **{"class": "read"}),
    "write_note": dict(desc="Create a note. Refuses to replace an existing one unless overwrite=true.", schema=obj({**P, "content": {"type": "string"}, "overwrite": {"type": "boolean"}}, ["path", "content"]), fn=t_write, **{"class": "write"}),
    "patch_note": dict(desc="Replace exact text in a note. Fails as stale when old is missing or expected_mtime differs.", schema=obj({**P, "old": {"type": "string"}, "new": {"type": "string"}, "expected_mtime": {"type": "number"}, "replace_all": {"type": "boolean"}}, ["path", "old", "new"]), fn=t_patch, **{"class": "write"}),
    "update_frontmatter": dict(desc="Set or remove frontmatter keys.", schema=obj({**P, "set": {"type": "object"}, "remove": {"type": "array", "items": {"type": "string"}}}, ["path"]), fn=t_update_fm, **{"class": "write"}),
    "manage_tags": dict(desc="Add or remove frontmatter tags.", schema=obj({**P, "add": {"type": "array", "items": {"type": "string"}}, "remove": {"type": "array", "items": {"type": "string"}}}, ["path"]), fn=t_tags, **{"class": "write"}),
    "move_note": dict(desc="Move or rename a note. Refuses to overwrite.", schema=obj({**P, "new_path": {"type": "string"}}, ["path", "new_path"]), fn=lambda a: move(a, True), sensitive=True, **{"class": "destructive"}),
    "move_file": dict(desc="Move or rename any vault file. Refuses to overwrite.", schema=obj({**P, "new_path": {"type": "string"}}, ["path", "new_path"]), fn=lambda a: move(a, False), sensitive=True, **{"class": "destructive"}),
    "delete_note": dict(desc="Move a note to .trash with a timestamp. Never deletes permanently.", schema=obj(P, ["path"]), fn=t_delete, sensitive=True, **{"class": "destructive"}),
}


def status_loop():
    while True:
        try:
            with open(STATUS, "w") as f:
                json.dump({"auth": "ok", "conflicts": len(conflicts())}, f)
        except OSError:
            pass
        time.sleep(300)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "purge-trash":
        purge(float(sys.argv[2]) if len(sys.argv) > 2 else 0)
    else:
        threading.Thread(target=status_loop, daemon=True).start()
        serve("everything", TOOLS)
