"""Minimal stdio MCP server loop shared by the fleet and mail servers."""
import json
import sys


def obj(props=None, required=None):
    return {"type": "object", "properties": props or {}, "required": required or []}


def serve(name, tools):
    """tools: {name: dict(desc, schema, fn, sensitive=False, ro=False)}"""

    def send(m):
        sys.stdout.write(json.dumps(m) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        id_, method, p = msg.get("id"), msg.get("method"), msg.get("params") or {}
        if id_ is None:
            continue
        if method == "initialize":
            res = {"protocolVersion": p.get("protocolVersion", "2025-06-18"),
                   "capabilities": {"tools": {}}, "serverInfo": {"name": name, "version": "0.1.0"}}
        elif method == "tools/list":
            res = {"tools": [{"name": n, "description": t["desc"], "inputSchema": t["schema"],
                              "annotations": {"readOnlyHint": bool(t.get("ro"))},
                              "_sensitive": bool(t.get("sensitive")), **({"_class": t["class"]} if t.get("class") else {})}
                             for n, t in tools.items()]}
        elif method == "tools/call":
            t = tools.get(p.get("name"))
            if t is None:
                send({"jsonrpc": "2.0", "id": id_, "error": {"code": -32602, "message": "unknown tool"}})
                continue
            try:
                out = t["fn"](p.get("arguments") or {})
                res = {"content": [{"type": "text", "text": out if isinstance(out, str)
                                    else json.dumps(out, indent=2, ensure_ascii=False)}]}
            except Exception as e:  # tool failures go back to the model as text
                res = {"content": [{"type": "text", "text": str(e) or type(e).__name__}], "isError": True}
        elif method == "ping":
            res = {}
        else:
            send({"jsonrpc": "2.0", "id": id_, "error": {"code": -32601, "message": "method not found"}})
            continue
        send({"jsonrpc": "2.0", "id": id_, "result": res})
