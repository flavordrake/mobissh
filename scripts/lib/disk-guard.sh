#!/usr/bin/env bash
# scripts/lib/disk-guard.sh — preflight for anything that writes gigabytes.
#
# 2026-09-13: / hit 100% mid-arc; the fast gate died at +2208 with
# "tee: No space left on device" and the APK build with ENOSPC — 40 minutes
# lost to a condition that was knowable in 10ms. Consumers call disk_guard
# BEFORE starting: below the soft floor it runs scripts/disk-reclaim.sh (age
# and merged-branch guarded), escalating once to a 1-day cache age; still
# below the hard floor it fails LOUD so the job never starts.
#
# Usage: source scripts/lib/disk-guard.sh; disk_guard [label]
# Env: DISK_GUARD_SOFT_G (default 20), DISK_GUARD_HARD_G (default 5),
#      DISK_GUARD_PATH (default /), DISK_GUARD_SKIP=1 to bypass.

disk_guard() {
  local label="${1:-disk-guard}"
  [[ "${DISK_GUARD_SKIP:-0}" = "1" ]] && return 0
  local soft="${DISK_GUARD_SOFT_G:-20}" hard="${DISK_GUARD_HARD_G:-5}" path="${DISK_GUARD_PATH:-/}"
  local here reclaim avail
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  reclaim="${here}/../disk-reclaim.sh"
  avail=$(df --output=avail -B1G "$path" | tail -n 1 | tr -d ' ')
  (( avail >= soft )) && return 0
  echo "> [${label}] ${avail}G free on ${path} (< ${soft}G): reclaiming" >&2
  DISK_RECLAIM_DF_PATH="$path" "$reclaim" --quiet || true
  avail=$(df --output=avail -B1G "$path" | tail -n 1 | tr -d ' ')
  if (( avail < soft )); then
    echo "> [${label}] still ${avail}G: reclaiming 1-day-old build caches" >&2
    DISK_RECLAIM_DF_PATH="$path" "$reclaim" --quiet --max-age-days 0 || true
    avail=$(df --output=avail -B1G "$path" | tail -n 1 | tr -d ' ')
  fi
  if (( avail < hard )); then
    echo "! [${label}] DISK FULL: ${avail}G free on ${path} after reclaim (< ${hard}G) — refusing to start. Run scripts/disk-reclaim.sh --dry-run and free the rest by hand." >&2
    return 1
  fi
  echo "> [${label}] ${avail}G free after reclaim" >&2
  return 0
}
