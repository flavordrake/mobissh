#!/usr/bin/env bash
# scripts/disk-reclaim.sh — free the root overlay when builds die with
# "No space left on device" (PR D agent, 2026-09-13: / at 100%, 1.0G free).
#
# Three sinks account for nearly everything we own:
#   1. /tmp/android-dev/emulator-*.qcow2 — scratch disks the RETIRED local
#      emulator left behind on every crash (24G of them). The fleet device
#      (#1098) never writes here, so anything older than a day is garbage.
#   2. native/.dart_tool/flutter_build/<hash>/ in the main checkout (15G): one
#      ~92M dir per build TARGET, so every integration_test file leaves its own.
#   3. native/build + native/.dart_tool inside agent worktrees whose branch is
#      already merged (8.9G for #1141): `gh-ops.sh integrate` keeps the worktree
#      (#235, cleanup deferred to release) but the build output is regenerable.
#
# Refuses to touch qcow2 files while a live emulator/qemu exists. Never removes
# a worktree itself — only the build output inside it.
#
# Callers: scripts/lib/disk-guard.sh (build/test/ship preflight), gh-ops.sh
# integrate (post-merge), .claude/hooks/disk-guard-hook.sh (session start).
#
# Usage: scripts/disk-reclaim.sh [--dry-run] [--max-age-days N] [--quiet]
#   --max-age-days N   flutter_build dirs older than N days go (default 7)
#   --quiet            no per-file lines, just the summary
# Env (tests): DISK_RECLAIM_ROOT (main repo root), DISK_RECLAIM_TMP
#   (emulator scratch dir, default /tmp/android-dev), DISK_RECLAIM_DF_PATH.
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# From an agent worktree, git-common-dir points at the MAIN repo's .git — clean
# the main checkout's caches and all worktrees regardless of where we run.
MAIN_ROOT="$(dirname "$(git -C "$SCRIPT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$SCRIPT_ROOT/.git")")"
REPO_ROOT="${DISK_RECLAIM_ROOT:-$MAIN_ROOT}"
SCRATCH_DIR="${DISK_RECLAIM_TMP:-/tmp/android-dev}"
DF_PATH="${DISK_RECLAIM_DF_PATH:-/}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/disk-reclaim.log"
exec > >(tee -a "$LOGFILE") 2>&1

DRY=0
MAX_AGE=7
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --max-age-days) MAX_AGE="$2"; shift ;;
    --quiet) QUIET=1 ;;
    *) echo "Usage: $0 [--dry-run] [--max-age-days N] [--quiet]" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "> [disk-reclaim] $*"; }
avail_g() { df --output=avail -B1G "$DF_PATH" | tail -n 1 | tr -d ' '; }
before=$(avail_g)
log "$(date -u +%FT%TZ) start: ${before}G free on ${DF_PATH} (dry-run=${DRY}, max-age=${MAX_AGE}d, root=${REPO_ROOT})"

REMOVED=0
remove() {
  # $1 = path; prints the size first so the log shows what each step bought.
  local size
  size=$(du -xsh "$1" 2>/dev/null | cut -f1)
  if (( DRY )); then
    log "would remove ${size} ${1}"
  else
    rm -rf -- "$1"
    (( QUIET )) || log "removed ${size} ${1}"
  fi
  REMOVED=$((REMOVED + 1))
}

# 1. Stale local-emulator scratch disks.
live=$(ps -eo pid,stat,comm | awk '($3 ~ /qemu-system|emulator/) && ($2 !~ /Z/) {print $1}' || true)
if [[ -n "$live" ]]; then
  log "live emulator/qemu (PIDs: ${live}) — skipping ${SCRATCH_DIR} qcow2 cleanup"
elif [[ -d "$SCRATCH_DIR" ]]; then
  while IFS= read -r f; do
    remove "$f"
  done < <(find "$SCRATCH_DIR" -maxdepth 1 -name 'emulator-*.qcow2' -mtime +1)
fi

# 2. Main-checkout Flutter build caches older than MAX_AGE days.
fb="${REPO_ROOT}/native/.dart_tool/flutter_build"
if [[ -d "$fb" ]]; then
  while IFS= read -r d; do
    remove "$d"
  done < <(find "$fb" -mindepth 1 -maxdepth 1 -type d -mtime +"$MAX_AGE")
fi

# 3. Build output inside worktrees whose branch is already merged into main.
#    The worktree stays (release-time cleanup); only native/build and
#    native/.dart_tool go.
for wt in "${REPO_ROOT}"/.claude/worktrees/agent-*; do
  [[ -d "$wt/native" ]] || continue
  branch=$(git -C "$wt" branch --show-current 2>/dev/null || true)
  [[ -n "$branch" ]] || continue
  if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$branch" main 2>/dev/null; then
    continue   # unmerged work may be mid-build; leave it
  fi
  for sub in native/build native/.dart_tool; do
    [[ -d "$wt/$sub" ]] && remove "$wt/$sub"
  done
done

after=$(avail_g)
log "done: ${after}G free on ${DF_PATH} (was ${before}G, ${REMOVED} paths)"
