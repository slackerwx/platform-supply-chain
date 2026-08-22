# Multi-stage on purpose: the builder carries uv and the build backend, the final image carries neither.
# Base image is fully qualified and pinned to a patch version — `disallow-latest-tag` and
# `restrict-image-registries` (platform-policies) reject anything looser.
FROM ghcr.io/astral-sh/uv:0.12.5 AS uv

FROM docker.io/library/python:3.14.7-slim AS builder
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /app
# Dependency layer first so source edits do not invalidate it (there are no runtime deps today, but the
# consumer repositories that copy this Dockerfile do have them).
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
# --no-editable: the final stage copies only /app/.venv, so an editable install would point at a /app/src
# that does not exist there and `python -m hello.app` would fail at runtime.
RUN uv sync --frozen --no-dev --no-editable

FROM docker.io/library/python:3.14.7-slim
RUN useradd --uid 10001 --create-home hello
WORKDIR /app
COPY --from=builder /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
USER 10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"]
ENTRYPOINT ["python", "-m", "hello.app"]
