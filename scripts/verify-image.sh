#!/usr/bin/env bash
# verify-image.sh — check, from outside the pipeline, that an image really carries what this repo promises:
# a cosign keyless signature issued to a slackerwx GitHub Actions workflow, a signed SPDX SBOM, and SLSA
# build provenance. This is the same assertion Kyverno makes at admission time, run by a human.
#
#   ./scripts/verify-image.sh ghcr.io/slackerwx/platform-supply-chain-hello:abc1234
#
# Private GHCR packages need a token with `read:packages`:
#   GHCR_TOKEN=ghp_… ./scripts/verify-image.sh <image>
#
# An image built by a private repo on a personal account has no SLSA provenance — GitHub will not
# issue one. Say so, and the provenance check is reported as expected-absent instead of failed:
#   EXPECT_PROVENANCE=false ./scripts/verify-image.sh <image>
#
# Overridable: OWNER, ISSUER, IDENTITY_REGEXP, GHCR_USER, EXPECT_PROVENANCE.
set -euo pipefail

OWNER="${OWNER:-slackerwx}"
GHCR_USER="${GHCR_USER:-$OWNER}"
ISSUER="${ISSUER:-https://token.actions.githubusercontent.com}"
# Same shape as the Kyverno rule `verify-images-slackerwx` in platform-policies — keep the two in sync.
IDENTITY_REGEXP="${IDENTITY_REGEXP:-^https://github\.com/${OWNER}/[^/]+/\.github/workflows/[^@]+@refs/(heads/main|tags/v[0-9]+(\.[0-9]+)*)\$}"

if [ -t 1 ]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; DIM=""; BOLD=""; RESET=""
fi

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
}

[ $# -eq 1 ] || usage
IMAGE="$1"

missing=0
for tool in cosign jq gh openssl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "${RED}missing required tool: $tool${RESET}" >&2; missing=1; }
done
[ "$missing" -eq 0 ] || exit 69

# Only cosign needs the registry credential here; `gh attestation verify` uses your existing `gh auth` session
# and this script deliberately does not touch it.
if [ -n "${GHCR_TOKEN:-}" ]; then
  echo "$GHCR_TOKEN" | cosign login ghcr.io --username "$GHCR_USER" --password-stdin >/dev/null
fi

failures=0
log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

# check <label> <command...> — quiet on success, full output on failure.
check() {
  local label="$1"; shift
  printf '  %-34s' "$label"
  if "$@" >"$log_file" 2>&1; then
    printf '%sOK%s\n' "$GREEN" "$RESET"
  else
    printf '%sFAIL%s\n' "$RED" "$RESET"
    sed 's/^/      /' "$log_file"
    failures=$((failures + 1))
  fi
}

# Decode the DSSE envelopes until the SPDX one shows up, then summarise it for a human.
sbom_summary() {
  local line payload
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # cosign v3 emits Sigstore bundles (DSSE under .dsseEnvelope); v2 emitted the bare envelope.
    payload="$(printf '%s' "$line" | jq -r '.dsseEnvelope.payload // .payload // empty' \
      | openssl base64 -d -A 2>/dev/null || true)"
    [ -n "$payload" ] || continue
    if printf '%s' "$payload" | jq -e '.predicateType | test("spdx"; "i")' >/dev/null 2>&1; then
      printf '%s' "$payload" | jq -r '
        "  SPDX \(.predicate.spdxVersion // "?") · \(.predicate.packages | length) packages · created \(.predicate.creationInfo.created // "?")"'
      printf '%s' "$payload" | jq -r '
        .predicate.packages | sort_by(.name) | .[:8][] | "    - \(.name) \(.versionInfo // "")"'
      return 0
    fi
  done < <(cosign download attestation "$IMAGE" 2>/dev/null)
  echo "  could not read an SPDX attestation from the registry" >&2
  return 1
}

echo "${BOLD}Verifying${RESET} $IMAGE"
echo "${DIM}  issuer   $ISSUER${RESET}"
echo "${DIM}  identity $IDENTITY_REGEXP${RESET}"
echo

check "cosign signature" \
  cosign verify \
    --certificate-oidc-issuer "$ISSUER" \
    --certificate-identity-regexp "$IDENTITY_REGEXP" \
    "$IMAGE"

check "SBOM attestation (spdx)" \
  cosign verify-attestation --type spdxjson \
    --certificate-oidc-issuer "$ISSUER" \
    --certificate-identity-regexp "$IDENTITY_REGEXP" \
    "$IMAGE"

if [ "${EXPECT_PROVENANCE:-true}" = "false" ]; then
  printf '  %-34s%sSKIP%s %s(attest_provenance=false: signed and inventoried, but cannot prove which commit built it)%s\n' \
    "SLSA build provenance" "$DIM" "$RESET" "$DIM" "$RESET"
else
  check "SLSA build provenance" \
    gh attestation verify "oci://${IMAGE}" --owner "$OWNER"
fi

echo
echo "${BOLD}SBOM${RESET}"
if ! sbom_summary; then
  failures=$((failures + 1))
fi

echo
if [ "$failures" -eq 0 ]; then
  if [ "${EXPECT_PROVENANCE:-true}" = "false" ]; then
    echo "${GREEN}${BOLD}PASS${RESET} — signature and SBOM verify for $IMAGE ${DIM}(no provenance by design)${RESET}"
  else
    echo "${GREEN}${BOLD}PASS${RESET} — signature, SBOM and provenance all verify for $IMAGE"
  fi
  exit 0
fi
echo "${RED}${BOLD}FAIL${RESET} — $failures check(s) failed for $IMAGE"
echo "${DIM}A private GHCR package needs GHCR_TOKEN with read:packages. An image built outside the reusable"
echo "workflow has no signature at all — that is the expected result, not a bug in this script.${RESET}"
exit 1
