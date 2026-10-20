"""Authenticated streamable-HTTP MCP gateway over stdio or remote children, with a per-tool allowlist and audit log."""
import hmac
import json
import os
import queue
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get(os.environ.get("GATEWAY_TOKEN_ENV", "MCP_TOKEN"), "")
POLICY = os.environ.get("MCP_POLICY", "/policy/tools.json")
CATALOG_FILE = os.environ.get("CATALOG_FILE", "")
HEALTH_FILE = os.environ.get("HEALTH_FILE", "")
PASSTHRU = os.environ.get("GATEWAY_PASSTHRU") == "1"  # inner gateway: forward tools untouched, outer one enforces policy
CHILDREN = json.loads(os.environ.get("GATEWAY_CHILDREN", "[]"))
PORT = int(os.environ.get("PORT", "8080"))
REDACT = {"body", "text", "html", "content", "password", "token", "secret", "key", "attachments", "old", "new", "expected"}
MAX_FAILS, WINDOW = 5, 600
fails = {}
fails_lock = threading.Lock()


def audit(**kw):
    print(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), **kw}, ensure_ascii=False), flush=True)


def summarize(args, allow=None):
    """allow: when set, only these keys show a value (health and notes data stays out of the log)."""
    out = {}
    for k, v in (args if isinstance(args, dict) else {}).items():
        if k.lower() in REDACT or (allow is not None and k not in allow):
            out[k] = "<redacted>"
        else:
            s = json.dumps(v, ensure_ascii=False)
            out[k] = s if len(s) <= 60 else s[:57] + "..."
    return out


class Child:
    def __init__(self, spec):
        self.name, self.spec = spec["name"], spec
        self.lock = threading.Lock()
        self.proc = None
        self.q = None
        self.n = 0
        self.tools = None
        self.timeout = spec.get("timeout", 60)

    def _start(self):
        env = {k: os.environ[k] for k in self.spec.get("env", []) if k in os.environ}
        env.update(PATH=os.environ.get("PATH", ""), HOME="/tmp", PYTHONUNBUFFERED="1",
                   SSL_CERT_FILE=os.environ.get("SSL_CERT_FILE", ""))
        self.proc = subprocess.Popen(self.spec["cmd"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     text=True, env=env, bufsize=1)
        self.q = q = queue.Queue()
        proc = self.proc

        def pump():
            for line in proc.stdout:
                try:
                    q.put(json.loads(line))
                except ValueError:
                    pass
            q.put(None)

        threading.Thread(target=pump, daemon=True).start()
        self.n = 0
        self._rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "gateway", "version": "1"}}, 30)
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.proc.stdin.flush()

    def _rpc(self, method, params, timeout):
        self.n += 1
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.proc.stdin.flush()
        end = time.time() + timeout
        while True:
            try:
                m = self.q.get(timeout=max(0.1, end - time.time()))
            except queue.Empty:
                raise TimeoutError(f"{self.name} timed out")
            if m is None:
                raise RuntimeError(f"{self.name} exited")
            if m.get("id") == self.n:
                if "error" in m:
                    raise RuntimeError(m["error"].get("message", "error"))
                return m["result"]

    def rpc(self, method, params, timeout=None):
        with self.lock:
            if self.proc is None or self.proc.poll() is not None:
                self._start()
            try:
                return self._rpc(method, params, timeout or self.timeout)
            except (TimeoutError, RuntimeError, OSError):
                if self.proc and self.proc.poll() is None:
                    self.proc.kill()
                self.proc = None
                raise

    def list_tools(self):
        if self.tools is None:
            self.tools = self.rpc("tools/list", {})["tools"]
        return self.tools


class RemoteChild(Child):
    """Another gateway on the internal network (the garmin container)."""

    def rpc(self, method, params, timeout=None):
        req = urllib.request.Request(
            self.spec["url"], method="POST",
            data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
            headers={"Content-Type": "application/json", "Accept": "application/json",
                     "Authorization": "Bearer " + os.environ.get(self.spec["token_env"], "")})
        with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
            m = json.loads(r.read())
        if "error" in m:
            raise RuntimeError(m["error"].get("message", "error"))
        return m["result"]


children = [(RemoteChild if c.get("url") else Child)(c) for c in CHILDREN]
last_catalog = [None]


def policy():
    """None means the policy file is unreadable: fail closed."""
    try:
        with open(POLICY) as f:
            p = json.load(f)
        return {"disabled": set(p.get("disabled", [])), "enable": set(p.get("enable", [])),
                "classes": p.get("classes") or {}}
    except FileNotFoundError:
        return {"disabled": set(), "enable": set(), "classes": {}}
    except (OSError, ValueError, AttributeError):
        return None


def visible(child, name, cls, pol):
    if name in pol["disabled"]:
        return False
    if cls is None:
        return True
    if name in pol["enable"]:
        return True
    allowed = pol["classes"].get(child.name, child.spec.get("classes", ["read", "write"]))
    return cls in ("read", "write") and cls in allowed


def catalog():
    pol = policy()
    out, everything = {}, []
    if pol is None and not PASSTHRU:
        return out
    for c in children:
        try:
            tools = c.list_tools()
        except Exception as e:
            audit(event="child_error", child=c.name, error=str(e))
            continue
        for t in tools:
            name = t["name"]
            if name in out:
                continue
            t = dict(t)
            cls = t.pop("_class", None) if not PASSTHRU else t.get("_class")
            sensitive = bool(t.get("_sensitive")) or cls == "destructive"
            if PASSTHRU:
                out[name] = (c, t, False, cls)
                continue
            t.pop("_sensitive", None)
            ok = visible(c, name, cls, pol)
            everything.append({"tool": name, "child": c.name, "class": cls or ("sensitive" if sensitive else "-"),
                               "visible": ok})
            if not ok:
                continue
            if sensitive:
                t["description"] += " REQUIRES USER CONFIRMATION: ask the user first, then pass confirm=true."
                schema = json.loads(json.dumps(t["inputSchema"]))
                schema.setdefault("properties", {})["confirm"] = {
                    "type": "boolean", "description": "Must be true, only after the user confirmed."}
                t["inputSchema"] = schema
            out[name] = (c, t, sensitive, cls)
    if CATALOG_FILE and everything and everything != last_catalog[0]:
        last_catalog[0] = everything
        try:
            with open(CATALOG_FILE, "w") as f:
                json.dump(sorted(everything, key=lambda e: (e["child"], e["class"], e["tool"])), f, indent=0)
        except OSError:
            pass
    return out


def tool_error(text):
    return {"content": [{"type": "text", "text": text}], "isError": True}


def call(name, args, ip):
    t0 = time.time()
    entry = catalog().get(name)
    if entry is None:
        audit(event="call", tool=name, status="denied", reason="unknown or disabled", ip=ip)
        return None
    child, tool, sensitive, cls = entry
    args = dict(args or {})
    confirmed = args.pop("confirm", False) is True
    summary = summarize(args, child.spec.get("log"))
    extra = {"class": cls} if cls else {}
    if sensitive and not confirmed and not PASSTHRU:
        audit(event="call", tool=name, sensitive=True, status="needs_confirmation", args=summary, ip=ip, **extra)
        return tool_error(f"{name} requires user confirmation. Ask the user, then retry with confirm=true.")
    try:
        res = child.rpc("tools/call", {"name": name, "arguments": args})
        status = "error" if res.get("isError") else "ok"
    except Exception as e:
        res, status = tool_error(f"{name} failed: {e}"), "failed"
    flag = {"alert": "sensitive_call"} if sensitive and not PASSTHRU else {}
    audit(event="call", tool=name, sensitive=sensitive, status=status, args=summary,
          ms=int((time.time() - t0) * 1000), ip=ip, **extra, **flag)
    return res


def handle(msg, ip):
    id_, method, p = msg.get("id"), msg.get("method"), msg.get("params") or {}
    if id_ is None:
        return None
    if method == "initialize":
        res = {"protocolVersion": p.get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}},
               "serverInfo": {"name": "kowal-mcp-gateway", "version": "0.2.0"}}
    elif method == "tools/list":
        res = {"tools": [t for _, t, _, _ in catalog().values()]}
    elif method == "tools/call":
        res = call(p.get("name"), p.get("arguments"), ip)
        if res is None:
            return {"jsonrpc": "2.0", "id": id_, "error": {"code": -32602, "message": "unknown tool"}}
    elif method == "ping":
        res = {}
    else:
        return {"jsonrpc": "2.0", "id": id_, "error": {"code": -32601, "message": "method not found"}}
    return {"jsonrpc": "2.0", "id": id_, "result": res}


def health():
    s = {}
    if HEALTH_FILE:
        try:
            with open(HEALTH_FILE) as f:
                s = json.load(f)
        except (OSError, ValueError):
            pass
    if s.get("auth") == "reauth":
        return 503, b"re-authentication needed"
    return 200, ("ok" + (f" conflicts={s['conflicts']}" if "conflicts" in s else "")).encode()


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "gw"

    def log_message(self, *a):
        pass

    def ip(self):
        return self.headers.get("CF-Connecting-IP") or self.client_address[0]

    def reply(self, code, body=b"", ctype="application/json", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        ip, now = self.ip(), time.time()
        with fails_lock:
            recent = [t for t in fails.get(ip, []) if t > now - WINDOW]
            fails[ip] = recent
            if len(recent) >= MAX_FAILS:
                audit(event="auth", status="locked_out", ip=ip, alert="repeated_auth_failure")
                self.reply(429, b'{"error":"too many failures"}')
                return False
        got = self.headers.get("Authorization", "")
        if hmac.compare_digest(got.encode(), f"Bearer {TOKEN}".encode()):
            return True
        with fails_lock:
            fails[ip].append(now)
            n = len(fails[ip])
        # shape only, never the value: enough to tell a missing header from a wrong one
        hdr = "absent" if not got else f"scheme={got.split(' ')[0][:10]} len_ok={len(got) == len(TOKEN) + 7}"
        audit(event="auth", status="failed", ip=ip, count=n, method=self.command, path=self.path.split("?")[0][:60],
              header=hdr, ua=self.headers.get("User-Agent", "")[:40], **({"alert": "repeated_auth_failure"} if n >= 3 else {}))
        self.reply(401, b'{"error":"unauthorized"}', extra={"WWW-Authenticate": "Bearer"})
        return False

    def do_GET(self):
        if self.path == "/healthz":
            code, body = health()
            return self.reply(code, body, "text/plain")
        if self.path.startswith("/.well-known/"):  # no OAuth here: say so instead of 401 so clients do not start a sign-in flow
            return self.reply(404, b'{"error":"no oauth"}')
        if self.authed():
            self.reply(405, b"", extra={"Allow": "POST"})

    def do_HEAD(self):
        self.reply(200 if self.path == "/healthz" else 405, b"", "text/plain")

    def do_OPTIONS(self):
        self.reply(204, b"", extra={"Allow": "POST, GET, OPTIONS"})

    def do_DELETE(self):
        if self.authed():
            self.reply(405, b"", extra={"Allow": "POST"})

    def do_POST(self):
        if not self.authed():
            return
        if self.path.split("?")[0] != "/mcp":
            return self.reply(404, b'{"error":"not found"}')
        n = int(self.headers.get("Content-Length") or 0)
        if n > 1_000_000:
            return self.reply(413)
        try:
            body = json.loads(self.rfile.read(n))
        except ValueError:
            return self.reply(400, b'{"error":"bad json"}')
        ip = self.ip()
        if isinstance(body, list):
            out = [r for r in (handle(m, ip) for m in body) if r]
        else:
            out = handle(body, ip)
        if not out:
            return self.reply(202)
        self.reply(200, json.dumps(out).encode())


if __name__ == "__main__":
    if len(TOKEN) < 32:
        sys.exit("MCP_TOKEN missing or shorter than 32 chars, refusing to start")
    audit(event="start", children=[c.name for c in children], passthrough=PASSTHRU)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
