#!/usr/bin/env bash
# scripts/lib/next-build-version.sh — decide the version a ship should publish.
#
# PURE + TESTABLE on purpose: this logic shipped a reused Android versionCode once
# (v0.1.11 went out as +162, the number already spent by 0.1.10+162, because a
# manual semver edit silently suppressed the build bump). Anything that decides a
# versionCode should be exercisable without running a build.
#
#   next_build_version <current-version> <committed-version>
#
# Rules:
#   - SEMVER and BUILD NUMBER are independent. Editing the semver must NOT freeze
#     the build number.
#   - A deliberate BUILD edit is respected, but must strictly advance past the
#     committed one (versionCode must strictly increase for Play, #966).
#   - Otherwise the build number advances from the COMMITTED value, carrying any
#     manual semver forward.
#
# Prints the version to ship on stdout. Exits 2 with a message on stderr when the
# input is unparseable or a manual build number fails to advance.
set -euo pipefail

next_build_version() {
  local cur="${1:?current version required}"
  local head="${2:?committed version required}"

  local cur_base="${cur%+*}" cur_build="${cur##*+}"
  if [[ "$cur" != *+* || ! "$cur_build" =~ ^[0-9]+$ ]]; then
    echo "cannot parse build number in '${cur}'" >&2
    return 2
  fi

  local head_base="${head%+*}" head_build="${head##*+}"
  [[ "$head_build" =~ ^[0-9]+$ ]] || head_build=0

  if [[ "$cur_build" != "$head_build" ]]; then
    if (( cur_build <= head_build )); then
      echo "manual build ${cur_build} does not advance past committed ${head_build}" >&2
      return 2
    fi
    printf '%s\n' "$cur"          # deliberate build edit — respect it
    return 0
  fi

  printf '%s\n' "${cur_base}+$((head_build + 1))"   # carries a manual semver forward
  return 0
}

# Allow direct invocation for tests / manual checks.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  next_build_version "$@"
fi
