"""HTTP client for the PLK API. The only module that talks to the network about PLK."""
import gzip
import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request

from .limiter import Denied
from .schema import SchemaError, validate

log = logging.getLogger("plk.client")
MAX_BODY = 64 * 1024 * 1024


class NoKey(Exception):
    pass


class ApiError(Exception):
    def __init__(self, msg, status=None):
        super().__init__(msg)
        self.status = status


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):
        return None


class Client:
    def __init__(self, cfg, limiter, schemas, opener=None):
        self.api = cfg["api"]
        self.limiter = limiter
        self.schemas = schemas
        self.opener = opener or urllib.request.build_opener(_NoRedirect)
        self.requests_total = 0

    def _key(self):
        try:
            with open(self.api["key_file"]) as f:
                key = f.read().strip()
        except OSError:
            raise NoKey("key file unreadable")
        if not key:
            raise NoKey("key file empty")
        return key

    def get(self, path, params=None, schema=None, prio="rt"):
        """Returns (parsed_json, lowercase_headers). Raises Denied, NoKey, ApiError or SchemaError."""
        key = self._key()
        self.limiter.acquire(prio)
        q = urllib.parse.urlencode(sorted((params or {}).items()))
        url = self.api["base_url"] + path + ("?" + q if q else "")
        req = urllib.request.Request(url, headers={
            "X-API-Key": key,
            "X-Api-Version": self.api["api_version"],
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
            "User-Agent": self.api["user_agent"],
        })
        t0 = time.monotonic()
        status, headers, body = 0, {}, b""
        try:
            with self.opener.open(req, timeout=self.api["timeout_s"]) as r:
                status, headers, body = r.status, r.headers, r.read(MAX_BODY + 1)
        except urllib.error.HTTPError as e:
            status, headers = e.code, e.headers
            try:
                body = e.read(MAX_BODY + 1)
            except OSError:
                body = b""
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            self._log(path, 0, t0, 0, {}, type(e).__name__)
            self.limiter.record(0)
            raise ApiError("network error: %s" % type(e).__name__)
        self.requests_total += 1
        headers = {k.lower(): v for k, v in dict(headers).items()}
        ctype = headers.get("content-type", "")
        odd = status == 200 and ("json" not in ctype or len(body) > MAX_BODY)
        self._log(path, status, t0, len(body), headers, "odd-content" if odd else "")
        self.limiter.record(-1 if odd else status, headers)
        if odd:
            raise ApiError("unexpected content type %r" % ctype.split(";")[0], status)
        if status != 200:
            raise ApiError("http %d" % status, status)
        try:
            if headers.get("content-encoding") == "gzip":
                body = gzip.decompress(body)
            data = json.loads(body)
        except (OSError, ValueError):
            raise ApiError("undecodable body", status)
        if schema:
            validate(self.schemas, schema, data)
        return data, headers

    def _log(self, path, status, t0, size, headers, note):
        log.info("req path=%s status=%s ms=%d bytes=%d rem_h=%s rem_d=%s%s", path, status,
                 (time.monotonic() - t0) * 1000, size,
                 headers.get("x-ratelimit-hourly-remaining", "-"),
                 headers.get("x-ratelimit-daily-remaining", "-"),
                 " note=" + note if note else "")


__all__ = ["Client", "ApiError", "NoKey", "Denied", "SchemaError"]
