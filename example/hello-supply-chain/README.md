# hello-supply-chain

The example application of [`platform-supply-chain`](../../README.md). It is deliberately useless: a stdlib-only
HTTP server on `:8080` with two routes.

| Route | Response |
|---|---|
| `GET /healthz` | `{"status":"ok"}` |
| `GET /` | `{"app":"hello-supply-chain","version":"0.1.0"}` |
| anything else | `404` `{"error":"not found","path":"…"}` |

## Why it exists

Every push to `main` builds this into `ghcr.io/slackerwx/platform-supply-chain-hello:<sha7>` through the same
reusable workflow other repositories call. The image is then described (SBOM), scanned, signed and attested, and a
separate `verify` job asserts all of it from the outside. If the pipeline breaks, this repository's own CI is the
first thing to go red — the workflows are never "probably fine".

It has **no runtime dependencies** on purpose. The SBOM of a `python:3.12-slim` image with no third-party packages is
short enough to read line by line, which is what makes the `docs/LEARNING.md` exercises possible.

## Local development

```bash
uv sync --extra dev
uv run ruff check . && uv run ruff format --check .
uv run mypy
uv run pytest -q --cov --cov-report=term-missing
uv run python -m hello.app        # serves on :8080
```

The container image is **not** buildable on the owner's Mac (Docker Desktop is broken there); the build is exercised
in CI. See `Dockerfile` for the non-root, pinned-base-image layout the cluster policies require.
