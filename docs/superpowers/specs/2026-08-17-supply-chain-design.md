# platform-supply-chain — Design

**Date**: 2026-08-17 · **Status**: Specified — implementation pending (reusable workflows already written, everything
else pending) · **Approach**: reusable GitHub Actions workflows that build, describe (SBOM), scan, **sign** and
**attest** every container image of the lab, plus a verifier — consumed by every other repo and enforced in-cluster by
Kyverno.

## 1. Context
Every homelab image is built by GitHub Actions and pushed to **private GHCR packages**
(`ghcr.io/slackerwx/<name>:<sha7>`, pulled with `imagePullSecrets: [ghcr-secret]`). Today each repo re-implements its own
build job (see `platform-finops/.github/workflows/ci.yml`): no SBOM, no vulnerability gate, no signature, no provenance.
Meanwhile `platform-policies` ships the Kyverno rule `verify-images-slackerwx`, which requires that images from
`ghcr.io/slackerwx/*` carry a **cosign keyless signature issued to a GitHub Actions workflow of a `slackerwx` repo on
`main`**. That rule is in Audit today and cannot move to Enforce until a pipeline produces those signatures — this repo
is that pipeline, and therefore a hard dependency of every other pillar that builds an image
(`platform-finops`, `platform-sre-agent`, and anything created by the Backstage golden paths).

This is also the pillar that maps most directly to what regulated companies ask for: SBOM inventory, vulnerability
gates, artifact signing and SLSA provenance as auditable evidence.

## 2. Goals / Non-goals
**Goals** — one reusable `workflow_call` pipeline that any repo can adopt in ~10 lines; SPDX + attached SBOM;
vulnerability scan with a configurable severity gate and SARIF in the GitHub Security tab; cosign **keyless** signature
(no key material anywhere); SLSA build provenance attached to the image in the registry; an independent **verify** job
that fails if any of the above is missing; an example application that proves the whole chain on every push; a `v1` tag
consumers can pin; documentation an auditor could read.

**Non-goals (backlog)** — SLSA Build L3 via `slsa-framework/slsa-github-generator` (evaluated, see §5), VEX documents,
in-toto layouts beyond what GitHub attestations provide, signing of Helm charts/OCI artifacts other than images,
self-hosted Fulcio/Rekor, container image mirroring/proxying.

## 3. Architecture

```mermaid
flowchart LR
  subgraph Consumer repo (finops, sre-agent, golden paths...)
    CI[ci.yml] -->|uses: .../reusable-container.yml@v1| RC
  end
  subgraph platform-supply-chain
    RC[reusable-container.yml] --> B[buildx build+push]
    B --> S[Syft → SBOM SPDX]
    S --> G[Grype → SARIF + gate]
    S --> AT[cosign attest spdxjson]
    B --> SG[cosign sign · keyless]
    B --> PV[attest-build-provenance → registry]
    RC --> V[verify job: cosign verify · verify-attestation · gh attestation verify]
  end
  SG -->|cert from| F[(Fulcio)] --- R[(Rekor transparency log)]
  B --> GHCR[(ghcr.io/slackerwx/*)]
  GHCR -->|admission| KY[Kyverno verify-images-slackerwx]
  G -->|SARIF| SEC[GitHub code scanning]
```

Nothing runs in the cluster: this pillar has **no ArgoCD Application and no namespace**. Its output is (a) reusable
workflows referenced by other repos and (b) signatures/attestations in GHCR that Kyverno checks at admission time.

## 4. Components and decisions

| Component | Version (verified 2026-08-17) | Decision |
|---|---|---|
| `actions/checkout` | `v7.0.1` = `3d3c42e5aac5ba805825da76410c181273ba90b1` (`gh api repos/actions/checkout/releases/latest` + tag ref) | every action pinned **by commit SHA** with the version in a trailing comment — tags are mutable, and this repo must practice what it preaches |
| `docker/setup-buildx-action` | `v4.2.0` = `bb05f3f5519dd87d3ba754cc423b652a5edd6d2c` | buildx for cache + multi-platform |
| `docker/login-action` | `v4.6.0` = `dbcb813823bdd20940b903addbd779551569679f` | GHCR login with `GITHUB_TOKEN` |
| `docker/metadata-action` | `v6.2.0` = `dc802804100637a589fabce1cb79ff13a1411302` | tags: `sha7` (the homelab deploy convention), branch, semver |
| `docker/build-push-action` | `v7.3.0` = `53b7df96c91f9c12dcc8a07bcb9ccacbed38856a` | `provenance: false, sbom: false` — we attach our own so the digest stays a single manifest that cosign/Kyverno handle cleanly |
| `anchore/sbom-action` (Syft) | `v0.24.0` = `e22c389904149dbc22b58101806040fa8d37a610`; Syft `v1.51.0` | SBOM in **SPDX JSON** (widest tool support) |
| `anchore/scan-action` (Grype) | `v7.4.0` = `e1165082ffb1fe366ebaf02d8526e7c4989ea9d2`; Grype `v0.117.0` | scans **the SBOM** (not the image again) → faster and identical inventory |
| `sigstore/cosign-installer` | `v4.1.2` = `6f9f17788090df1f26f669e9d70d6ae9567deba6`; cosign `v3.1.3` | keyless signing/attestation |
| `actions/attest-build-provenance` | `v4.2.2` = `4d101475d8b20a2381f78447822ac1eab6504dd8` | SLSA-style provenance, `push-to-registry: true` |
| `github/codeql-action/upload-sarif` | `v4` = `988661ebb5e81487b3fb31b2185d2856c0a10679` | SARIF upload, `continue-on-error` (private repos without GHAS reject it) |
| `ossf/scorecard-action` | `v2.4.4` = `2d1146689b8cda280b9bc96326124645441f03bc` | weekly repo posture score, `publish_results: false` (private) |
| `astral-sh/setup-uv` | `v10.0.1` = `20cfd1bf945f4377ade1205e4dbc17946fc9a30d`; uv `0.12.5` | Python quality workflow |
| `aquasecurity/trivy-action` | `v0.36.0` = `ed142fd0673e97e23eac54620cfb913e5ce36c25` | IaC misconfiguration scan |
| `kubeconform` | `v0.7.0` (GitHub releases) | manifest schema validation in the IaC workflow |
| Example app base image | `python:3.12.14-slim` (Docker Hub tag list) | fully qualified + pinned → satisfies `restrict-image-registries` and `disallow-latest-tag` |

**Keyless over long-lived keys.** cosign keyless mints a short-lived certificate from Fulcio bound to the workflow's
OIDC identity and records it in Rekor. There is no private key to store, rotate or leak, and the *identity* (repo +
workflow + ref) is what the Kyverno policy asserts. Rejected: a cosign key pair in a GitHub secret (key management
burden, and a leaked key signs anything).

**GitHub artifact attestations for provenance, not slsa-github-generator.** `actions/attest-build-provenance` produces a
signed provenance statement, pushes it to the registry alongside the image and is verifiable with both
`gh attestation verify` and `cosign verify-attestation`. The SLSA generator reaches a higher formal level (isolated
builder) but adds a second build path and much more complexity for a homelab. Documented in `docs/slsa.md` as the
upgrade path.

**Scan the SBOM, gate on `critical` by default.** `fail_on_severity` is an input; the example app uses `critical` so a
new HIGH CVE in a base image does not block unrelated work, while the SARIF still lands in the Security tab. Consumers
that want stricter behaviour pass `fail_on_severity: high`.

**`push: false` on pull requests.** The `ci.yml` of a consumer passes `push: ${{ github.event_name != 'pull_request' }}`:
PRs still build and scan (fast feedback) but do not publish or sign — signatures must only ever be produced from `main`,
because that is exactly what the Kyverno subject regex trusts.

## 5. Interfaces (what consumers depend on)

`reusable-container.yml` — `workflow_call`:

| Input | Type | Default | Meaning |
|---|---|---|---|
| `image_name` | string | *(required)* | image name without registry → `ghcr.io/<owner>/<image_name>` |
| `context` | string | `.` | build context |
| `dockerfile` | string | `Dockerfile` | path from repo root |
| `platforms` | string | `linux/amd64` | buildx platforms |
| `push` | boolean | `true` | publish + sign + attest |
| `fail_on_severity` | string | `critical` | Grype gate: negligible/low/medium/high/critical |
| `only_fixed` | boolean | `true` | gate only on findings that have a fix (added 2026-08-22, see the addendum) |

Outputs: `image` (`ghcr.io/owner/name@sha256:…`), `digest`, `tags`. Required caller permissions: `contents: read`,
`packages: write`, `id-token: write`, `attestations: write`, `security-events: write`.

`reusable-python-quality.yml` — inputs `working-directory` (`.`), `python-version` (`3.12`), `run-mypy` (`true`); runs
`uv sync --extra dev`, ruff check + format check, mypy, pytest with coverage.

`reusable-iac-scan.yml` — inputs `path` (`.`), `kubeconform-paths` (space-separated dirs; kustomize dirs are built
first), `trivy-severity` (`HIGH,CRITICAL`).

**Contract with `platform-policies`** (must not drift): issuer `https://token.actions.githubusercontent.com`, subject
regex `^https://github\.com/slackerwx/[^/]+/\.github/workflows/[^@]+@refs/heads/main$`, `mutateDigest: true`. Because
the identity is the *called* workflow file, consumers get identity
`https://github.com/slackerwx/platform-supply-chain/.github/workflows/reusable-container.yml@refs/heads/main` — the regex
covers it, and the verify job asserts the same thing from the outside.

### Repository layout to build
```
.github/workflows/reusable-container.yml        ✅ written (build·sbom·scan·sign·attest + verify job)
.github/workflows/reusable-python-quality.yml   ✅ written
.github/workflows/reusable-iac-scan.yml         ✅ written
.github/workflows/scorecard.yml                 ✅ written
.github/workflows/ci.yml                        ✅ written (dogfoods the three reusable workflows)
.github/dependabot.yml · .github/CODEOWNERS      ✅ written
example/hello-supply-chain/                     ⬜ pyproject.toml · src/hello/__init__.py · src/hello/app.py ·
                                                   tests/test_app.py · Dockerfile · README.md
scripts/verify-image.sh                         ⬜ cosign verify + verify-attestation + SBOM summary for humans
docs/slsa.md                                    ⬜ what we produce, what each level requires, evidence map
docs/LEARNING.md · docs/runbook.md              ⬜ pt-BR
SECURITY.md · LICENSE · catalog-info.yaml       ⬜
README.md                                       ⬜ how to consume, with the 10-line snippet
```

The example app is deliberately tiny: a stdlib-only HTTP server (`http.server`) exposing `/healthz` and `/` on
:8080, one pytest, a non-root Dockerfile (`USER 10001`, `python:3.12.14-slim`). It exists to prove the pipeline, not to
be useful; keeping it dependency-free means its SBOM is small enough to read by hand in the learning exercises.

## 6. Security
No secrets are stored: `GITHUB_TOKEN` (scoped per job) plus OIDC. Least privilege is expressed per job — the top-level
`permissions: {}` in every workflow forces each job to opt in. The verify job runs in a **separate job** with its own
narrow permissions so that verification cannot be influenced by the build step. Private GHCR packages require a registry
login even for `cosign verify`, which is why the verify job logs in — and why Kyverno needs `ghcr-secret` in the
`kyverno` namespace (documented in both repos).

Nothing here runs in-cluster, so no NetworkPolicy/PSS applies; the *output* must satisfy the enforced policies:
fully-qualified pinned base images, non-root containers, and — recursively — signatures for the images this repo itself
publishes (`platform-supply-chain-hello`).

## 7. Testing and validation
Offline (on the Mac): `actionlint` over `.github/workflows`, `shellcheck scripts/*.sh`, `python3 -c "import yaml,glob;[list(yaml.safe_load_all(open(f))) for f in glob.glob('.github/workflows/*.yml')]"`,
and `docker build` of the example app **is not possible** (Docker Desktop is broken on this machine) — the build is
exercised in CI instead.

In CI (this repo's `ci.yml`): `quality` (uv/ruff/mypy/pytest on the example), `iac` (Trivy config scan), `container`
(the full chain, `push` only outside PRs), `lint-workflows` (actionlint + shellcheck). The `verify` job inside
`reusable-container.yml` is the real end-to-end assertion: it fails if the signature, the SBOM attestation or the
provenance is missing or issued to an unexpected identity.

Cannot be validated here: Kyverno actually admitting/denying based on these signatures (needs the cluster — the
`platform-policies` kind e2e covers the policy logic, not the real signatures).

## 8. Owner checklist
1. Nothing to seal — this pillar uses only `GITHUB_TOKEN` and OIDC.
2. After the first green run on `main`, verify by hand from your Mac:
   `GHCR_TOKEN=<PAT read:packages> ./scripts/verify-image.sh ghcr.io/slackerwx/platform-supply-chain-hello:<sha7>`
3. Cut the consumable tag: `git tag -a v1 -m "reusable supply-chain workflows v1" && git push origin v1`
   (re-point `v1` with `git tag -f v1 && git push -f origin v1` when the workflows change; consumers pin `@v1`).
4. Migrate `platform-finops` to the reusable workflow (replace its build job with a `uses:` call) and re-tag its image so
   the running deployment is a signed one.
5. Only then flip `verify-images-slackerwx` to Enforce in `platform-policies` (its `overlays/enforce` already does that —
   so do steps 3–4 **before** switching that Application's path).

## 9. Implementation notes for the executing agent
Work in `/Users/slackerwx/Developer/slackerwx/platform-supply-chain` (already `git init`-ed, workflows present,
**no commits yet**). Do not modify the existing workflow files except where a task says so.

1. **Example app** — create `example/hello-supply-chain/{pyproject.toml,src/hello/__init__.py,src/hello/app.py,tests/test_app.py,Dockerfile,README.md}`. `pyproject.toml`: name `hello-supply-chain`, `requires-python = ">=3.12,<3.13"`, no runtime deps, dev extra `pytest==9.1.1 pytest-cov==7.1.0 ruff==0.16.3 mypy==2.3.1`, hatchling build with `packages = ["src/hello"]`, ruff `line-length = 100`, mypy `strict`. `app.py`: `http.server` handler answering `/healthz` → `{"status":"ok"}` and `/` → `{"app":"hello-supply-chain","version":__version__}`, `serve(port: int = 8080)`. Test: start the server on an ephemeral port in a thread, assert both routes. Validate: `cd example/hello-supply-chain && uv sync --extra dev && uv run ruff check . && uv run mypy && uv run pytest -q`.
2. **Dockerfile** — multi-stage on `python:3.12.14-slim`, `useradd --uid 10001`, copy `src/`, `USER 10001`, `EXPOSE 8080`, `ENTRYPOINT ["python","-m","hello.app"]`, `HEALTHCHECK` optional. Expected: no root user, no package manager left in the final layer.
3. **verify-image.sh** — `scripts/verify-image.sh <image-ref>`: `cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity-regexp '^https://github\.com/slackerwx/'`, then `cosign verify-attestation --type spdxjson …`, then `cosign download attestation … | jq` to print package count, then `gh attestation verify oci://<ref> --owner slackerwx`. Must `set -euo pipefail`, print a green/red summary, and exit non-zero on any failure. Validate with `bash -n` and `shellcheck`.
4. **Docs** — `docs/slsa.md` (what SLSA levels require, which we meet with GitHub attestations, what would be needed for L3, how to read a provenance statement, how an auditor verifies without trusting us); `SECURITY.md` (how to report, supported versions, what we sign); `README.md` (what it is + the consumer snippet below + the verification commands + status); `docs/LEARNING.md` and `docs/runbook.md` in **pt-BR** (see §10 below); `LICENSE` (MIT, Danilo Gomes); `catalog-info.yaml` (Component, `owner: user:slackerwx`, `system: homelab`, `github.com/project-slug`, `backstage.io/techdocs-ref: dir:.`, tags `supply-chain, sigstore, sbom, slsa, github-actions`).
   Consumer snippet to document verbatim:
   ```yaml
   jobs:
     container:
       uses: slackerwx/platform-supply-chain/.github/workflows/reusable-container.yml@v1
       permissions: {contents: read, packages: write, id-token: write, attestations: write, security-events: write}
       with:
         image_name: my-service
         push: ${{ github.event_name != 'pull_request' }}
   ```
5. **Validate everything offline** — `actionlint` (download the v1.7.7 binary), `shellcheck scripts/*.sh`, YAML parse of every workflow. Expected: clean.
6. **Commit and publish** — Conventional Commits with the `Claude-Session:` trailer, then `gh repo create slackerwx/platform-supply-chain --private --description "Secure software supply chain for the homelab: reusable SBOM/scan/sign/attest workflows" --source . --remote origin --push`.
7. **Make CI green** — `gh run watch <id> --exit-status`; expect `container` to push `ghcr.io/slackerwx/platform-supply-chain-hello:<sha7>` and the `verify` job to pass. Common failures: SARIF upload rejected on a private repo (already `continue-on-error`), `attestations: write` missing in a caller, Grype gate tripping on the base image (bump `python:3.12.x-slim`).
8. **Tag `v1`** and record the exact digest of the first signed image in the README "proof" section.

## 10. Learning material (pt-BR, `docs/LEARNING.md`)
Cobrir: diferença entre **assinatura** (quem construiu), **SBOM** (o que tem dentro) e **provenance** (como foi
construído); por que keyless (Fulcio/Rekor) substitui gestão de chaves; o que é SLSA e quais níveis existem; por que
`:latest` quebra a cadeia; como um auditor verifica sem confiar em você. Exercícios: (1) editar a imagem manualmente
(`crane mutate`) e ver `cosign verify` falhar; (2) introduzir uma dependência com CVE crítica e ver o gate barrar;
(3) publicar uma imagem sem passar pelo workflow e ver o Kyverno reportar em Audit; (4) apagar a attestation e ver o
job `verify` quebrar; (5) trocar `fail_on_severity` para `high` e medir quanto ruído aparece.

## 11. Backlog
SLSA L3 via `slsa-github-generator`; VEX (`openvex`) para suprimir CVEs não exploráveis; assinatura de charts/manifests
OCI; `cosign policy` como gate no CD além do admission; mirror local de imagens públicas (Harbor/zot) para não depender
de rate limits; Renovate no lugar do Dependabot para agrupar bumps de SHA.

## 12. Addendum — 2026-08-22 (implementation)

Written after implementing §9/§10; the sections above are the design as of 2026-08-17 and are left intact.

- **`only_fixed` input added, default `true`.** The first CI run failed the gate on seven CRITICAL CVEs from the
  base image — five in `perl-base`, one (twice) in `libc-bin`/`libc6` — all marked *wont-fix* by Debian.
  `python:3.12.14-slim` is already the newest 3.12.x, so the remedy suggested in §9.7 ("bump `python:3.12.x-slim`")
  does not exist. Gating and reporting were split: the gate now blocks on what a build can act on, and a second
  non-blocking Grype run publishes every finding to the job summary and uploads it as `vulnerabilities-<name>`.
  Nothing is hidden — the attested SBOM also lets anyone re-scan under a stricter policy later.
- **`reusable-container.yml` pull-request path fixed.** The reference step exported `<IMAGE>:local` when
  `push: false`, but `load: true` loads the `metadata-action` tags, so Syft failed on every pull request. It now
  takes the first tag from `steps.meta.outputs.tags`, and reads tags through the environment rather than direct
  interpolation.
- **`ruff` pinned to `0.16.4`** (0.16.3 in the §4 table was stale by 2026-08-22). `mypy 2.3.1`, `pytest 9.1.1`,
  `pytest-cov 7.1.0` and `hatchling 1.32.0` re-verified unchanged.
- **`uv sync --no-editable` in the example Dockerfile.** The final stage copies only `/app/.venv`; an editable
  install would resolve to a `/app/src` that does not exist there.

The full task list and the reasoning behind each deviation are in
`docs/superpowers/plans/2026-08-22-supply-chain.md`.
