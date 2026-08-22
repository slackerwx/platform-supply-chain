# Security Policy

## Reporting a vulnerability

This is a personal lab repository, not a product with an on-call rotation. Even so, if you find a way to make this
pipeline sign, attest or admit something it should not:

- Open a [private security advisory](https://github.com/slackerwx/platform-supply-chain/security/advisories/new) on
  this repository. Please do **not** open a public issue for anything that would let someone forge a signature or
  bypass the admission policy.
- Expect a first response within a week. There is no bounty.

Useful in a report: the image reference or workflow run, the exact commands you ran, and what you expected the
`verify` job or `scripts/verify-image.sh` to do differently.

## Supported versions

| Ref | Supported |
|---|---|
| `v1` (moving tag consumers pin) | ✅ — fixes land here |
| `main` | ✅ — development; `v1` is re-pointed at it after CI is green |
| any older tag or commit SHA | ❌ |

`v1` is deliberately a moving tag: consumers pin `@v1` and get security fixes to the workflows without a pull
request in every repository. Pin a commit SHA instead if you want the opposite trade-off.

## What we sign, and what that means

Every image published from `main` through `reusable-container.yml` carries:

- a **cosign keyless signature**, whose certificate identity is the calling workflow file at
  `refs/heads/main`, issued by `https://token.actions.githubusercontent.com` and logged in Rekor;
- a **signed SPDX SBOM**, attached as an in-toto attestation (`--type spdxjson`);
- **SLSA build provenance** (`actions/attest-build-provenance`, pushed to the registry).

A signature attests **who built the artifact and from what**, not that the artifact is free of vulnerabilities. The
Grype gate is a separate, deliberately configurable control — see `docs/slsa.md` § Known limits.

## Trust boundaries

- **No secret material exists in this repository.** Signing uses OIDC and short-lived Fulcio certificates; the only
  credential in play is the per-job `GITHUB_TOKEN`. There is no key to rotate and none to leak.
- **Every workflow starts from `permissions: {}`**, so each job has to opt in to what it needs. The `verify` job
  runs as a *separate* job with its own narrow permissions (`packages: read`, `attestations: read`) — verification
  must not be influenceable by the step that produced the thing being verified.
- **Pull requests never sign.** Callers pass `push: ${{ github.event_name != 'pull_request' }}`. A fork's pull
  request builds and scans, and can publish nothing. This matters because the Kyverno rule trusts the *identity*
  `…@refs/heads/main` — anything that could sign from another ref would break that assumption.
- **Every action is pinned by commit SHA.** Tags are mutable and a compromised action tag is the classic supply
  chain attack this repository exists to talk about. Dependabot proposes SHA bumps weekly.
- **Branch protection on `main` is the real perimeter.** With keyless signing, whoever can merge to `main` can cause
  a trusted signature to be produced. Key management has been traded for merge-access management, on purpose.
