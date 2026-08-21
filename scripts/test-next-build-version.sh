#!/usr/bin/env bash
# scripts/test-next-build-version.sh — cover the version-bump rules that decide a
# published Android versionCode. Case 2 is the regression that shipped v0.1.11 as
# a reused +162.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib/next-build-version.sh"

PASS=0
FAIL=0

expect() {
  local desc="$1" cur="$2" head="$3" want="$4" got
  if got="$(next_build_version "$cur" "$head" 2>/dev/null)"; then
    if [[ "$got" == "$want" ]]; then
      echo "+ $desc"; PASS=$((PASS + 1))
    else
      echo "! $desc — wanted '$want', got '$got'"; FAIL=$((FAIL + 1))
    fi
  else
    echo "! $desc — unexpected failure (wanted '$want')"; FAIL=$((FAIL + 1))
  fi
}

expect_reject() {
  local desc="$1" cur="$2" head="$3"
  if next_build_version "$cur" "$head" >/dev/null 2>&1; then
    echo "! $desc — expected rejection, but it succeeded"; FAIL=$((FAIL + 1))
  else
    echo "+ $desc"; PASS=$((PASS + 1))
  fi
}

# 1. Clean tree: ordinary ship advances the build.
expect "clean tree bumps the build" \
  "0.1.11+163" "0.1.11+163" "0.1.11+164"

# 2. THE REGRESSION: semver hand-bumped for a release, build untouched. The build
#    must still advance — this shipped as a reused +162 before the fix.
expect "manual semver still bumps the build" \
  "0.1.11+162" "0.1.10+162" "0.1.11+163"

# 3. Deliberate build edit is respected (e.g. skipping a burnt number).
expect "manual build number is respected" \
  "0.1.11+170" "0.1.11+162" "0.1.11+170"

# 4. A manual build that does NOT advance is refused — versionCode must strictly
#    increase for Play (#966).
expect_reject "refuses a build number that does not advance" \
  "0.1.11+160" "0.1.11+162"
expect_reject "refuses a build number equal to committed-1 edge" \
  "0.1.11+161" "0.1.11+162"

# 5. Unparseable input fails loudly rather than shipping something wrong.
expect_reject "rejects a version with no build number" \
  "0.1.11" "0.1.11+162"
expect_reject "rejects a non-numeric build number" \
  "0.1.11+beta" "0.1.11+162"

# 6. Semver AND build both moved — respect the explicit build.
expect "semver + build both edited respects the build" \
  "0.2.0+200" "0.1.11+162" "0.2.0+200"

# 7. Pre-release stages (docs/VERSIONING.md) ride in the base untouched, and B
#    stays globally monotonic across every stage transition. These lock the
#    lifecycle in as contract, not accident.
expect "rc build within a candidate lineage bumps the build" \
  "0.1.12-rc.1+166" "0.1.12-rc.1+166" "0.1.12-rc.1+167"
expect "rc promotion (rc.1 → rc.2) still bumps the build" \
  "0.1.12-rc.2+167" "0.1.12-rc.1+167" "0.1.12-rc.2+168"
expect "final promotion (rc.N → release) still bumps the build" \
  "0.1.12+167" "0.1.12-rc.3+167" "0.1.12+168"
expect "next dev cycle continues the global counter" \
  "0.1.13-dev+168" "0.1.12+168" "0.1.13-dev+169"
expect_reject "refuses a per-version build reset (B never resets)" \
  "0.1.13-dev+1" "0.1.12-rc.3+167"

echo
echo "> next-build-version: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
