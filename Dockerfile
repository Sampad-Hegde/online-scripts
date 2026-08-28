# ---------------------------------------------------------------------
#  online-script - serves hardware test shell scripts over HTTP
# ---------------------------------------------------------------------
FROM python:3.13-slim AS base

ARG APP_VERSION=1.0.0

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    APP_VERSION=${APP_VERSION} \
    SCRIPTS_DIR=/app/scripts \
    PORT=8080

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
COPY scripts/ ./scripts/

# unprivileged runtime user
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["python", "-c", \
         "import os,urllib.request,sys; \
          u='http://127.0.0.1:'+os.environ.get('PORT','8080')+'/healthz'; \
          sys.exit(0 if urllib.request.urlopen(u, timeout=4).status==200 else 1)"]

# single worker is plenty: this only serves a handful of small text files
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080} --no-server-header --proxy-headers --forwarded-allow-ips='*'"]
