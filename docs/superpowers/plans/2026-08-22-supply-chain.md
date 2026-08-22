# platform-supply-chain — Implementation plan

**Date**: 2026-08-22 · **Source**: `docs/superpowers/specs/2026-08-17-supply-chain-design.md` §9/§10 ·
**Status**: tasks 1–7 done; publishing

The three reusable workflows, `ci.yml`, `scorecard.yml`, `dependabot.yml` and `CODEOWNERS` were committed on
2026-08-17 (`cfcb3d0`). This plan builds everything the spec left as `⬜`: the example application that exercises the
pipeline, the human verification script, the documentation, and the `v1` tag consumers pin.

## Deviations from the spec (decided, not to be re-discussed)

1. **`ruff==0.16.4`, not `0.16.3`.** The spec pinned 0.16.3 on 2026-08-17; PyPI's latest stable on 2026-08-22 is
   0.16.4. Re-verified today: `mypy 2.3.1`, `pytest 9.1.1`, `pytest-cov 7.1.0`, `hatchling 1.32.0` are unchanged.
2. **`reusable-container.yml` is modified**, although §9 says not to touch the existing workflows. On a pull request
   the workflow sets `push: false`, and the `Digest reference` step then exports `image=<IMAGE>:local` — but
   `docker/build-push-action` with `load: true` loads the tags produced by `docker/metadata-action` (`<sha7>` on a PR),
   never `:local`. The Syft step therefore fails with "image not found" on **every** pull request, in this repo and in
   every consumer. The fix takes the first tag from `steps.meta.outputs.tags` instead of inventing `:local`. Left
   unfixed, the first push to `main` would still be green and the defect would only surface later, inside other
   pillars' repos.
3. **`docker.io/library/python:3.12.14-slim`** in the example Dockerfile, fully qualified rather than the bare
   `python:3.12.14-slim` of the spec table — the spec calls the base image "fully qualified" and only the registry
   prefix makes that true.
4. **`HEALTHCHECK` is present** (the spec called it optional), implemented with `urllib` so the slim image needs no
   `curl`/`wget` — it also silences Trivy's `DS026`.
5. **Coverage and mypy are configured for bare invocation.** `reusable-python-quality.yml` runs `uv run mypy` with no
   argument, `uv run ruff format --check .` and `uv run pytest -q --cov` with no source; the spec's validation
   commands omit all three. `pyproject.toml` therefore sets `[tool.mypy] packages/mypy_path` (finops style) and
   `[tool.coverage.run] source`.

6. **New input `only_fixed` (default `true`) on `reusable-container.yml`**, decided after the first CI run went red.
   `python:3.12.14-slim` carries seven CRITICAL CVEs (`perl-base` ×5, `libc-bin`/`libc6` ×1) that Debian marked
   *wont-fix*; 3.12.14 is already the newest 3.12.x, so the spec's suggested remedy in §9.7 ("bump
   `python:3.12.x-slim`") does not exist. A gate on unfixable findings would block every build in the lab forever.
   Gating and reporting were split: the gate blocks on actionable findings, a second non-blocking Grype run
   publishes every finding to the job summary and uploads it as `vulnerabilities-<image_name>`. Rejected: Alpine or
   distroless base (hides the CVEs by changing distro, and musl breaks manylinux wheels for real consumers) and
   `fail_on_severity: high`-style loosening (wrong axis — severity is not actionability).

7. **The repository is public** (owner decision, 2026-08-22). The first signed run failed with
   `Failed to persist attestation: Feature not available for user-owned private repositories`. Options put to the
   owner were: publish the repository, hand-roll a SLSA predicate with `cosign attest --type slsaprovenance`, or
   ship signature + SBOM without provenance. The owner chose to publish. Sanitisation check ran clean before the
   switch: no RFC1918 address, no `.k8s` hostname, no bucket name, no `svc.cluster.local` in tracked content.
   Follow-on edits: `scorecard.yml` now publishes results, and the SARIF and provenance comments were rewritten to
   describe the *consumer's* private-repo case rather than this one's.

## Tasks

- [x] 1. Example app — `pyproject.toml`, `src/hello/{__init__,app}.py`, `tests/test_app.py`, `README.md`
      Verify: `uv sync --extra dev && uv run ruff check . && uv run ruff format --check . && uv run mypy && uv run pytest -q --cov`
- [x] 2. `example/hello-supply-chain/Dockerfile` — multi-stage, non-root `USER 10001`, `EXPOSE 8080`
      Verify: read-through (Docker Desktop is broken on this Mac; the build runs in CI)
- [x] 3. Deviation 2 — fix the pull-request path of `reusable-container.yml`
      Verify: `actionlint`
- [x] 4. `scripts/verify-image.sh` — cosign verify + verify-attestation + SBOM summary + `gh attestation verify`
      Verify: `bash -n` and `shellcheck`
- [x] 5. Docs — `README.md`, `docs/slsa.md`, `SECURITY.md`, `LICENSE`, `catalog-info.yaml`
- [x] 6. Docs pt-BR — `docs/LEARNING.md` (≥5 break/fix exercises), `docs/runbook.md`
- [x] 7. Offline validation — `actionlint`, `shellcheck scripts/*.sh`, YAML parse of every workflow
- [ ] 8. Commit (Conventional Commits + `Claude-Session:` trailer) and
      `gh repo create slackerwx/platform-supply-chain --private --source . --remote origin --push`
- [ ] 9. CI green — `gh run watch <id> --exit-status`
- [ ] 10. Tag `v1` and record the first signed digest in the README "proof" section
