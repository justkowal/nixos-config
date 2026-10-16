import json
import os

probes: dict[str, dict] = {}
counts: dict[str, int | None] = {}


def probe(name, cmd):
    status, out = pi.execute(cmd)  # noqa: F821
    probes[name] = {"ok": status == 0, "detail": out.strip()[-300:]}
    return status == 0, out.strip()


def count(name, db, query):
    ok, out = probe(f"{name}-count", f"sqlite3 -readonly {db} '{query}'")
    counts[name] = int(out) if ok and out.isdigit() else None


pi.start()  # noqa: F821
try:
    pi.wait_for_unit("dr-import.service", timeout=1800)  # noqa: F821
    probes["import"] = {"ok": True, "detail": ""}
except Exception as e:
    probes["import"] = {"ok": False, "detail": str(e)[-300:]}

for unit in ["kanidm", "forgejo", "vaultwarden", "paperless-web", "woodpecker-server"]:
    try:
        pi.wait_for_unit(f"{unit}.service", timeout=600)  # noqa: F821
    except Exception as e:
        probes[f"{unit}-unit"] = {"ok": False, "detail": str(e)[-300:]}

for port in [8443, 3000, 8222, 28981, 8000]:
    try:
        pi.wait_for_open_port(port, timeout=300)  # noqa: F821
    except Exception:
        pass

user = os.environ.get("DR_KANIDM_USER", "justkowal")
probe("kanidm-status", "curl -sfk https://127.0.0.1:8443/status | grep -q true")
probe(
    "kanidm-login-init",
    "curl -sfk -H 'Content-Type: application/json' https://127.0.0.1:8443/v1/auth "
    f"""-d '{{"step":{{"init2":{{"username":"{user}","issue":"token","privileged":false}}}}}}'""",
)
probe("forgejo-api", "curl -sf 'http://127.0.0.1:3000/api/v1/repos/search?limit=1' | jq -e .ok")
probe("vaultwarden-alive", "curl -sf http://127.0.0.1:8222/alive")
probe("paperless-web", "test \"$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:28981/accounts/login/)\" = 200")
probe("woodpecker-healthz", "curl -sf http://127.0.0.1:8000/healthz")

count("forgejo_repos", "/var/lib/forgejo/data/forgejo.db", "select count(*) from repository")
count("paperless_documents", "/var/lib/paperless/db.sqlite3", "select count(*) from documents_document")
count("woodpecker_repos", "/var/lib/private/woodpecker-server/woodpecker.sqlite", "select count(*) from repos")
count("vaultwarden_users", "/var/lib/vaultwarden/db.sqlite3", "select count(*) from users")

with open(os.environ["DR_REPORT"], "w") as f:
    json.dump({"probes": probes, "counts": counts}, f, indent=2)

failed = [k for k, v in probes.items() if not v["ok"]]
if failed:
    raise Exception(f"failed probes: {', '.join(failed)}")
