# multi-arch index digest of python:3.12-slim-bookworm (amd64 + arm64)
FROM python:3.12-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 MPK_DATA=/data MPK_CONFIG=/app/config.toml
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --require-hashes -r requirements.txt
COPY adapter/ adapter/
COPY config.toml .
RUN useradd --system --uid 10001 mpk && mkdir /data && chown mpk /data
USER mpk
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=60s --timeout=5s --start-period=120s CMD python -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/health', timeout=4)"
CMD ["python", "adapter/main.py"]
