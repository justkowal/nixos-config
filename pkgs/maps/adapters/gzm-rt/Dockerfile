# same base and pins as plk-trains (python:3.12-slim-bookworm, multi-arch digest)
FROM python:3.12-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258 AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PYTHONPATH=/app/src PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --require-hashes --no-deps -r requirements.txt
COPY src ./src
COPY config.toml .

FROM base AS test
COPY tests ./tests
CMD ["python", "-m", "unittest", "discover", "-s", "tests"]

FROM base AS final
RUN useradd --system --uid 10001 --no-create-home gzm && mkdir /data && chown gzm /data
USER gzm
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=60s --timeout=5s --start-period=60s \
  CMD python -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/health', timeout=4)" || exit 1
CMD ["python", "-m", "gzm_rt"]
