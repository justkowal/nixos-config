"""Request governor for the PLK API: spacing, budgets, backoff, quota pause, breaker."""
import json
import logging
import os
import random
import threading
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

WAW = ZoneInfo("Europe/Warsaw")
log = logging.getLogger("plk.limiter")


class Denied(Exception):
    """Raised instead of sending a request. Nothing went on the wire."""

    def __init__(self, reason, until=None):
        super().__init__(reason)
        self.reason = reason
        self.until = until


def next_hour(now):
    return (int(now) // 3600 + 1) * 3600


def next_midnight(now):
    d = datetime.fromtimestamp(now, WAW)
    nxt = (d + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return nxt.timestamp()


def waw_date(ts):
    return datetime.fromtimestamp(ts, WAW).date()


def in_maintenance(now, margin_min):
    d = datetime.fromtimestamp(now, WAW)
    if d.weekday() != 1 or d.day > 7:
        return None
    start = d.replace(hour=20, minute=0, second=0, microsecond=0) - timedelta(minutes=margin_min)
    end = d.replace(hour=23, minute=59, second=59, microsecond=0) + timedelta(minutes=margin_min)
    if start <= d <= end:
        return end.timestamp()
    return None


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


class Limiter:
    def __init__(self, cfg, state_path, kill_path=None, clock=time.time, sleep=time.sleep,
                 rand=random.uniform):
        self.q = cfg["quota"]
        self.tiers = cfg["tiers"]
        self.state_path = state_path
        self.kill_path = kill_path
        self.clock, self.sleep, self.rand = clock, sleep, rand
        self.lock = threading.Lock()
        self.stamps = []
        self.last_req = 0.0
        self.errors = 0
        self.backoff_until = 0.0
        self.breaker_until = 0.0
        self.breaker_reason = None
        self.pause_until = 0.0
        self.pause_reason = None
        self.last_pause_end = 0.0
        self.limits = None
        self.remaining = {"hourly": None, "daily": None, "ts": 0.0}
        self.status_counts = {}
        self.tier = None
        self._load()

    # state ------------------------------------------------------------
    def _load(self):
        try:
            with open(self.state_path) as f:
                s = json.load(f)
        except (OSError, ValueError):
            return
        for k in ("stamps", "breaker_until", "breaker_reason", "pause_until", "pause_reason",
                  "limits", "remaining", "status_counts", "tier", "last_pause_end"):
            if k in s:
                setattr(self, k, s[k])
        self.stamps = [t for t in self.stamps if t > self.clock() - 86400 * 2]

    def _save(self):
        s = {k: getattr(self, k) for k in (
            "stamps", "breaker_until", "breaker_reason", "pause_until", "pause_reason",
            "limits", "remaining", "status_counts", "tier", "last_pause_end")}
        tmp = self.state_path + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(s, f)
            os.replace(tmp, self.state_path)
        except OSError as e:
            log.warning("state save failed: %s", e)

    # budgets ----------------------------------------------------------
    def _limits(self):
        if self.limits:
            return self.limits["hourly"], self.limits["daily"]
        t = self.tiers[self.q["assume_tier"]]
        return t["hourly"], t["daily"]

    def caps(self):
        h, d = self._limits()
        return int(h * self.q["hourly_fraction"]), int(d * self.q["daily_fraction"])

    def counts(self, now=None):
        now = self.clock() if now is None else now
        today = waw_date(now)
        hour = sum(1 for t in self.stamps if t > now - 3600)
        day = sum(1 for t in self.stamps if waw_date(t) == today)
        return hour, day

    def daily_allowance(self):
        """Requests the realtime loop may still spend today, honouring the API's own counters."""
        now = self.clock()
        h, d = self._limits()
        _, day_used = self.counts(now)
        _, day_cap = self.caps()
        left = day_cap - day_used
        rem = self.remaining["daily"]
        if rem is not None and waw_date(self.remaining["ts"]) == waw_date(now):
            left = min(left, rem - int(d * (1 - self.q["daily_fraction"])))
        return max(left, 0)

    def check(self, prio, now=None):
        now = self.clock() if now is None else now
        if os.environ.get("PLK_KILL") == "1" or (self.kill_path and os.path.exists(self.kill_path)):
            raise Denied("kill switch")
        if self.breaker_until > now:
            raise Denied("circuit breaker: %s" % self.breaker_reason, self.breaker_until)
        if self.pause_until > now:
            raise Denied("quota pause: %s" % self.pause_reason, self.pause_until)
        m = in_maintenance(now, self.q["maintenance_margin_min"])
        if m:
            raise Denied("plk maintenance window", m)
        if self.backoff_until > now:
            raise Denied("error backoff", self.backoff_until)
        h, d = self._limits()
        hour_used, day_used = self.counts(now)
        hf, df = self.q["hourly_fraction"], self.q["daily_fraction"]
        if prio == "static":
            hf, df = 0.9, 0.9
        if hour_used >= int(h * hf):
            raise Denied("own hourly budget used", next_hour(now))
        if day_used >= int(d * df):
            raise Denied("own daily budget used", next_midnight(now))
        floor = 1 - hf if prio != "static" else self.q["static_floor_fraction"]
        dfloor = 1 - df if prio != "static" else self.q["static_floor_fraction"]
        r = self.remaining
        if r["hourly"] is not None and now - r["ts"] < 3600 and r["hourly"] < h * floor:
            raise Denied("api hourly reserve reached", next_hour(r["ts"]))
        if r["daily"] is not None and waw_date(r["ts"]) == waw_date(now) and r["daily"] < d * dfloor:
            raise Denied("api daily reserve reached", next_midnight(now))

    def acquire(self, prio="rt"):
        with self.lock:
            self.check(prio)
            gap = self.q["min_spacing_s"] + self.rand(0, self.q["jitter_s"])
            wait = self.last_req + gap - self.clock()
            if wait > 0:
                self.sleep(wait)
            self.last_req = self.clock()
            self.stamps.append(self.last_req)
            self.stamps = self.stamps[-3000:]
            self._save()

    # outcomes ---------------------------------------------------------
    def trip_breaker(self, reason):
        now = self.clock()
        self.breaker_until = now + self.q["breaker_hours"] * 3600
        self.breaker_reason = reason
        log.error("breaker open reason=%s until=%s", reason, int(self.breaker_until))

    def record(self, status, headers=None):
        """Feed the outcome of one request. status 0 means network failure or timeout."""
        with self.lock:
            now = self.clock()
            headers = {k.lower(): v for k, v in (headers or {}).items()}
            self.status_counts[str(status)] = self.status_counts.get(str(status), 0) + 1
            lh = _int(headers.get("x-ratelimit-hourly-limit"))
            ld = _int(headers.get("x-ratelimit-daily-limit"))
            if lh and ld:
                self.limits = {"hourly": lh, "daily": ld}
                self.tier = next((n for n, t in self.tiers.items()
                                  if t["hourly"] == lh and t["daily"] == ld), "custom")
            rh = _int(headers.get("x-ratelimit-hourly-remaining"))
            rd = _int(headers.get("x-ratelimit-daily-remaining"))
            if rh is not None or rd is not None:
                self.remaining = {"hourly": rh, "daily": rd, "ts": now}

            if status == 200:
                self.errors = 0
                self.backoff_until = 0.0
            elif status == 429:
                self._on_429(headers, now)
            elif status == 401:
                self.pause_until = now + 3600
                self.pause_reason = "auth rejected (401)"
                log.error("auth rejected, pausing 1h")
            elif status == 403 or 300 <= status < 400 or status == -1:
                self.trip_breaker("ban signal status=%s" % status)
            else:
                self.errors += 1
                self.backoff_until = now + min(self.q["backoff_max_s"],
                                               self.q["backoff_base_s"] * 2 ** (self.errors - 1))
                if self.errors >= self.q["error_run_limit"]:
                    self.trip_breaker("run of %d errors" % self.errors)
            self._save()

    def _on_429(self, headers, now):
        ra = _int(headers.get("retry-after"))
        h, d = self._limits()
        _, day_used = self.counts(now)
        daily_gone = (self.remaining["daily"] == 0) or day_used >= int(d * 0.95)
        repeat = now - self.last_pause_end < 900
        if ra:
            until = now + ra
        elif daily_gone or repeat:
            until = next_midnight(now) + 300
        else:
            until = next_hour(now) + 60
        until += self.rand(0, 60)
        self.pause_until = until
        self.pause_reason = "429 quota (%s)" % ("daily" if until - now > 3700 else "hourly")
        self.last_pause_end = until
        log.warning("429 quota signal, pausing until %s", int(until))

    # health -----------------------------------------------------------
    def snapshot(self):
        now = self.clock()
        hc, dc = self.caps()
        hu, du = self.counts(now)
        h, d = self._limits()
        return {
            "tier": self.tier or ("assumed " + self.q["assume_tier"]),
            "limits": {"hourly": h, "daily": d},
            "caps": {"hourly": hc, "daily": dc},
            "used_by_adapter": {"last_hour": hu, "today": du},
            "api_remaining": {"hourly": self.remaining["hourly"], "daily": self.remaining["daily"],
                              "seen_age_s": int(now - self.remaining["ts"]) if self.remaining["ts"] else None},
            "breaker": {"open": self.breaker_until > now, "until": int(self.breaker_until) or None,
                        "reason": self.breaker_reason if self.breaker_until > now else None},
            "quota_pause": {"active": self.pause_until > now, "until": int(self.pause_until) or None,
                            "reason": self.pause_reason if self.pause_until > now else None},
            "kill_switch": bool(os.environ.get("PLK_KILL") == "1"
                                or (self.kill_path and os.path.exists(self.kill_path))),
            "status_counts": self.status_counts,
            "consecutive_errors": self.errors,
        }
