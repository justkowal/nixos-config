"""Request guard: spacing + jitter, hourly budget per lane, backoff, circuit breaker, kill switch.

Every outbound request goes through Guard.acquire() and reports back with Guard.record().
State is persisted so a restart cannot reset the budget or close an open breaker.
The floors below are code, not config: a config file cannot make the adapter faster than this.
"""
import json
import logging
import os
import random
import threading
import time
import urllib.error
import urllib.request

log = logging.getLogger("guard")

MIN_SPACING_S = 5.0
MAX_HOURLY_BUDGET = 240
MIN_COOLDOWN_S = 6 * 3600
BAN_STATUSES = {403, 429}
CHALLENGE_MARKERS = (b"cf-chl", b"just a moment", b"checking your browser", b"attention required", b"ray id")
BLOCK_MARKERS = (b"captcha", b"cf-chl", b"cloudflare", b"access denied", b"just a moment", b"bot detection")


class Blocked(Exception):
    """Raised instead of sending a request. Never retried through."""

    def __init__(self, msg, retry_in=None):
        super().__init__(msg)
        self.retry_in = retry_in


class SourceError(OSError):
    """Plain failure (timeout, 5xx, 404, bad payload). Backoff applies, no ban implied."""


class Guard:
    def __init__(self, state_dir, lanes, name="kp", spacing_s=5, jitter_s=3, hourly_budget=100,
                 backoff_base_s=30, backoff_max_s=900, cooldown_s=21600, error_run=5,
                 kill_file=None, clock=time.time, sleep=time.sleep, rand=random.uniform):
        self.spacing = max(float(spacing_s), MIN_SPACING_S)
        self.jitter = max(float(jitter_s), 0.0)
        self.budget = min(int(hourly_budget), MAX_HOURLY_BUDGET)
        self.lanes = {k: min(int(v), self.budget) for k, v in lanes.items()}
        self.backoff_base, self.backoff_max = backoff_base_s, backoff_max_s
        self.cooldown = max(int(cooldown_s), MIN_COOLDOWN_S)
        self.error_run = error_run
        self.kill_file = kill_file
        self.clock, self.sleep, self.rand = clock, sleep, rand
        self.path = os.path.join(state_dir, f"guard-{name}.json")
        self.name = name
        self.lock = threading.Lock()
        self.stamps = []  # [ts, lane]
        self.total_requests = 0
        self.breaker_until = 0.0
        self.breaker_reason = ""
        self.errors = 0
        self.last_ok = None
        self.last_status = None
        self.status_counts = {}
        self._load()

    def _load(self):
        try:
            with open(self.path) as f:
                s = json.load(f)
        except (OSError, ValueError):
            return
        self.stamps = [x for x in s.get("stamps", []) if x[0] > self.clock() - 3600]
        self.breaker_until = s.get("breaker_until", 0.0)
        self.breaker_reason = s.get("breaker_reason", "")
        self.last_ok = s.get("last_ok")
        self.total_requests = s.get("total_requests", 0)
        self.status_counts = s.get("status_counts", {})
        self.errors = s.get("errors", 0)

    def _save(self):
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump({"stamps": self.stamps, "breaker_until": self.breaker_until,
                           "breaker_reason": self.breaker_reason, "last_ok": self.last_ok,
                           "total_requests": self.total_requests, "status_counts": self.status_counts,
                           "errors": self.errors}, f)
            os.replace(tmp, self.path)
        except OSError as e:
            log.warning("cannot persist guard state: %s", e)

    def killed(self):
        return os.environ.get("KJ_KILL") == "1" or bool(self.kill_file and os.path.exists(self.kill_file))

    def breaker_open(self):
        return self.clock() < self.breaker_until

    def trip(self, reason):
        self.breaker_until = self.clock() + self.cooldown
        self.breaker_reason = reason
        log.error("circuit breaker OPEN for %ds: %s", self.cooldown, reason)
        self._save()

    def _prune(self):
        cut = self.clock() - 3600
        self.stamps = [x for x in self.stamps if x[0] > cut]

    def used(self, lane=None):
        self._prune()
        return sum(1 for _, ln in self.stamps if lane is None or ln == lane)

    def retry_in(self, lane):
        """Seconds until a request in this lane could be allowed, or 0."""
        now = self.clock()
        if self.killed():
            return 3600
        if self.breaker_open():
            return self.breaker_until - now
        self._prune()
        for pool, limit in ((self.stamps, self.budget),
                            ([x for x in self.stamps if x[1] == lane], self.lanes.get(lane, self.budget))):
            if len(pool) >= limit:
                return max(pool[len(pool) - limit][0] + 3600 - now, 1)
        return 0

    def acquire(self, lane):
        """Block until a request may be sent, or raise Blocked."""
        with self.lock:
            if self.killed():
                raise Blocked("kill switch", 3600)
            if self.breaker_open():
                raise Blocked("breaker open: " + self.breaker_reason, self.breaker_until - self.clock())
            wait_budget = self.retry_in(lane)
            if wait_budget:
                raise Blocked(f"hourly budget exhausted for lane {lane}", wait_budget)
            backoff = min(self.backoff_base * 2 ** (self.errors - 1), self.backoff_max) if self.errors else 0
            gap = self.spacing + self.rand(0, self.jitter) + backoff
            wait = (self.stamps[-1][0] + gap - self.clock()) if self.stamps else 0
            if wait > 0:
                self.sleep(wait)
            self.stamps.append([self.clock(), lane])
            self.total_requests += 1
            self._save()

    def record(self, status=None, error=False, redirected=False, blocked_body=False, soft=False):
        with self.lock:
            self.last_status = status
            if status is not None:
                self.status_counts[str(status)] = self.status_counts.get(str(status), 0) + 1
            log.info("status=%s error=%s used=%d/%d", status, error, self.used(), self.budget)
            if status in BAN_STATUSES:
                self.trip(f"HTTP {status}")
            elif redirected:
                self.trip("unexpected redirect")
            elif blocked_body:
                self.trip("bot challenge, block page or unexpected payload")
            elif error or (status is not None and status >= 400 and not soft):
                self.errors += 1
                if self.errors >= self.error_run:
                    self.trip(f"{self.errors} consecutive errors")
            else:
                self.errors = 0
                self.last_ok = self.clock()
            self._save()

    def health(self):
        now = self.clock()
        return {
            "breaker": "open" if self.breaker_open() else "closed",
            "breaker_until": self.breaker_until if self.breaker_open() else None,
            "breaker_reason": self.breaker_reason if self.breaker_open() else None,
            "requests_last_hour": self.used(),
            "hourly_budget": self.budget,
            "lanes_last_hour": {k: self.used(k) for k in self.lanes},
            "lane_budgets": self.lanes,
            "requests_total": self.total_requests,
            "consecutive_errors": self.errors,
            "last_status": self.last_status,
            "status_counts": self.status_counts,
            "last_ok_age_s": int(now - self.last_ok) if self.last_ok else None,
            "killed": self.killed(),
        }


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def fetch(guard, lane, url, user_agent, expect="json", must_contain=None, max_bytes=5_000_000, timeout=30,
          soft_404=False):
    """One guarded GET. Returns (status, headers, body). Raises Blocked or SourceError."""
    guard.acquire(lane)
    req = urllib.request.Request(url, headers={"User-Agent": user_agent, "Accept-Encoding": "identity"})
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
        raise SourceError(f"request failed: {e}") from e
    path = url.split("?")[0].split("//", 1)[-1].split("/", 1)[-1]
    log.info("GET /%s -> %s %d bytes %.2fs", path, status, len(body), time.monotonic() - t0)
    if len(body) > max_bytes:
        guard.record(error=True)
        raise SourceError("response too large")
    redirected = 300 <= status < 400
    blocked = False
    if status == 200:
        if expect == "json" and body[:1] not in (b"{", b"["):
            blocked = True
        if must_contain and must_contain not in body:
            blocked = True
        # the operator's pages mention "captcha" in their contact form, so only challenge-page phrases count here
        if expect == "html" and any(m in body[:8192].lower() for m in CHALLENGE_MARKERS):
            blocked = True
    elif status >= 400 and any(m in body[:4096].lower() for m in BLOCK_MARKERS):
        blocked = True
    soft = soft_404 and status == 404 and not blocked
    guard.record(status=status, redirected=redirected, blocked_body=blocked, soft=soft)
    if soft:
        return status, hdrs, body
    if redirected or blocked or status in BAN_STATUSES:
        raise Blocked(f"ban signal (status {status})", guard.cooldown)
    if status >= 400:
        raise SourceError(f"HTTP {status}")
    return status, hdrs, body
