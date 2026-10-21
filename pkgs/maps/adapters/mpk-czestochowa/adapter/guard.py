"""Per-source request guard: spacing + jitter, hourly budget, backoff, circuit breaker, kill switch.

Every outbound request, including websocket handshakes, goes through Guard.acquire()
and reports back with Guard.record(). State is persisted so a restart cannot reset
the budget or close an open breaker.
"""
import base64
import json
import logging
import os
import random
import threading
import time
import urllib.error
import urllib.request

log = logging.getLogger("guard")

BAN_STATUSES = {403, 429}
BLOCK_MARKERS = (b"captcha", b"cf-chl", b"cloudflare", b"access denied", b"just a moment")


class Blocked(Exception):
    """Raised instead of sending a request. Never retried by callers."""


class Guard:
    def __init__(self, name, state_dir, spacing_s, jitter_s, hourly_budget,
                 backoff_base_s=10, backoff_max_s=900, cooldown_s=21600, error_run=5,
                 kill_file=None, clock=time.time, sleep=time.sleep):
        self.name, self.spacing, self.jitter, self.budget = name, spacing_s, jitter_s, hourly_budget
        self.backoff_base, self.backoff_max = backoff_base_s, backoff_max_s
        self.cooldown, self.error_run = cooldown_s, error_run
        self.kill_file = kill_file
        self.clock, self.sleep = clock, sleep
        self.path = os.path.join(state_dir, f"guard-{name}.json")
        self.lock = threading.Lock()
        self.stamps = []
        self.breaker_until = 0.0
        self.breaker_reason = ""
        self.errors = 0
        self.last_ok = None
        self.last_status = None
        self._load()

    def _load(self):
        try:
            with open(self.path) as f:
                s = json.load(f)
            self.stamps = [t for t in s.get("stamps", []) if t > self.clock() - 3600]
            self.breaker_until = s.get("breaker_until", 0.0)
            self.breaker_reason = s.get("breaker_reason", "")
            self.last_ok = s.get("last_ok")
        except (OSError, ValueError):
            pass

    def _save(self):
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump({"stamps": self.stamps, "breaker_until": self.breaker_until,
                           "breaker_reason": self.breaker_reason, "last_ok": self.last_ok}, f)
            os.replace(tmp, self.path)
        except OSError as e:
            log.warning("%s: cannot persist guard state: %s", self.name, e)

    def killed(self):
        return os.environ.get("MPK_KILL") == "1" or bool(self.kill_file and os.path.exists(self.kill_file))

    def breaker_open(self):
        return self.clock() < self.breaker_until

    def trip(self, reason):
        self.breaker_until = self.clock() + self.cooldown
        self.breaker_reason = reason
        log.error("%s: circuit breaker OPEN for %ds: %s", self.name, self.cooldown, reason)
        self._save()

    def used_last_hour(self):
        now = self.clock()
        self.stamps = [t for t in self.stamps if t > now - 3600]
        return len(self.stamps)

    def acquire(self):
        """Block until a request may be sent, or raise Blocked."""
        with self.lock:
            if self.killed():
                raise Blocked(f"{self.name}: kill switch")
            if self.breaker_open():
                raise Blocked(f"{self.name}: breaker open: {self.breaker_reason}")
            if self.used_last_hour() >= self.budget:
                raise Blocked(f"{self.name}: hourly budget {self.budget} exhausted")
            backoff = min(self.backoff_base * 2 ** (self.errors - 1), self.backoff_max) if self.errors else 0
            gap = self.spacing + random.uniform(0, self.jitter) + backoff
            wait = (self.stamps[-1] + gap - self.clock()) if self.stamps else 0
            if wait > 0:
                self.sleep(wait)
            self.stamps.append(self.clock())
            self._save()

    def record(self, status=None, error=False, redirected=False, blocked_body=False):
        """Report an outcome. Ban signals trip the breaker immediately."""
        with self.lock:
            self.last_status = status
            log.info("%s: status=%s error=%s used=%d/%d", self.name, status, error,
                     self.used_last_hour(), self.budget)
            if status in BAN_STATUSES:
                self.trip(f"HTTP {status}")
            elif redirected:
                self.trip("unexpected redirect")
            elif blocked_body:
                self.trip("bot challenge or block page")
            elif error or (status is not None and status >= 500):
                self.errors += 1
                if self.errors >= self.error_run:
                    self.trip(f"{self.errors} consecutive errors")
            else:
                self.errors = 0
                self.last_ok = self.clock()
                self._save()

    def health(self):
        return {
            "breaker": "open" if self.breaker_open() else "closed",
            "breaker_until": self.breaker_until if self.breaker_open() else None,
            "breaker_reason": self.breaker_reason if self.breaker_open() else None,
            "requests_last_hour": self.used_last_hour(),
            "hourly_budget": self.budget,
            "consecutive_errors": self.errors,
            "last_status": self.last_status,
            "last_ok": self.last_ok,
            "killed": self.killed(),
        }


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def fetch(guard, url, user_agent, method="GET", headers=None, basic_auth=None,
          max_bytes=20_000_000, expect_json=False, timeout=30):
    """One guarded request. Returns (status, headers, body). Raises Blocked or OSError."""
    guard.acquire()
    h = {"User-Agent": user_agent, **(headers or {})}
    if basic_auth:
        h["Authorization"] = "Basic " + base64.b64encode(basic_auth.encode()).decode()
    req = urllib.request.Request(url, method=method, headers=h)
    t0 = time.monotonic()
    try:
        try:
            resp = _opener.open(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            resp = e
        status = resp.status if hasattr(resp, "status") else resp.code
        body = resp.read(max_bytes + 1)
        hdrs = {k.lower(): v for k, v in resp.headers.items()}
    except (OSError, urllib.error.URLError) as e:
        guard.record(error=True)
        raise OSError(f"{guard.name}: request failed: {e}") from e
    if len(body) > max_bytes:
        guard.record(error=True)
        raise OSError(f"{guard.name}: response larger than {max_bytes} bytes")
    log.info("%s: %s %s -> %s %d bytes %.2fs", guard.name, method, url.split("?")[0], status,
             len(body), time.monotonic() - t0)
    redirected = 300 <= status < 400
    blocked = (status == 200 and expect_json and body[:1] not in (b"[", b"{")) or \
              (status >= 400 and any(m in body[:4096].lower() for m in BLOCK_MARKERS))
    guard.record(status=status, redirected=redirected, blocked_body=blocked)
    if redirected or blocked or status in BAN_STATUSES:
        raise Blocked(f"{guard.name}: ban signal (status {status})")
    if status >= 400:
        raise OSError(f"{guard.name}: HTTP {status}")
    return status, hdrs, body
