#!/usr/bin/env bash
# scripts/test-disk-reclaim.sh — pin the safety rules of scripts/disk-reclaim.sh
# against a throwaway repo: only STALE scratch disks and OLD build caches go,
# only MERGED worktrees lose their build output, dry-run touches nothing, and
# lib/disk-guard.sh stays silent above its floor. Runs in the fast gate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECLAIM="${REPO_ROOT}/scripts/disk-reclaim.sh"
SANDBOX="$(mktemp -d "${MOBISSH_TMPDIR:-/tmp/mobissh}/disk-reclaim-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
export MOBISSH_LOGDIR="${SANDBOX}/logs"
export DISK_RECLAIM_TMP="${SANDBOX}/android-dev"
export DISK_RECLAIM_ROOT="${SANDBOX}/repo"
export DISK_RECLAIM_DF_PATH="$SANDBOX"

PASS=0
FAIL=0
ok()   { echo "+ $1"; PASS=$((PASS + 1)); }
bad()  { echo "! $1"; FAIL=$((FAIL + 1)); }
check_exists() { [[ -e "$2" ]] && ok "$1" || bad "$1 (missing: $2)"; }
check_gone()   { [[ ! -e "$2" ]] && ok "$1" || bad "$1 (still there: $2)"; }

# Fixture: a repo with main, a merged worktree branch and an unmerged one.
R="$DISK_RECLAIM_ROOT"
mkdir -p "$R" "$DISK_RECLAIM_TMP"
git -C "$R" init -q -b main
git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$R" worktree add -q -b merged-branch "$R/.claude/worktrees/agent-merged"
git -C "$R/.claude/worktrees/agent-merged" -c user.name=t -c user.email=t@t commit -q --allow-empty -m work
git -C "$R" merge -q --no-ff -m merge merged-branch
git -C "$R" worktree add -q -b open-branch "$R/.claude/worktrees/agent-open"
git -C "$R/.claude/worktrees/agent-open" -c user.name=t -c user.email=t@t commit -q --allow-empty -m wip
for wt in agent-merged agent-open; do
  mkdir -p "$R/.claude/worktrees/$wt/native/build" "$R/.claude/worktrees/$wt/native/.dart_tool"
  touch "$R/.claude/worktrees/$wt/native/build/app.apk"
done
mkdir -p "$R/native/.dart_tool/flutter_build/old" "$R/native/.dart_tool/flutter_build/new"
touch -d '10 days ago' "$R/native/.dart_tool/flutter_build/old"
touch "$DISK_RECLAIM_TMP/emulator-fresh.qcow2"
touch -d '3 days ago' "$DISK_RECLAIM_TMP/emulator-stale.qcow2"
touch -d '3 days ago' "$DISK_RECLAIM_TMP/other-stale.bin"

# 1. Dry run reports but removes nothing.
"$RECLAIM" --dry-run >/dev/null
check_exists "dry-run keeps the stale qcow2" "$DISK_RECLAIM_TMP/emulator-stale.qcow2"
check_exists "dry-run keeps the old build cache" "$R/native/.dart_tool/flutter_build/old"
check_exists "dry-run keeps merged worktree build output" "$R/.claude/worktrees/agent-merged/native/build"

# 2. Live run: age and merge rules.
"$RECLAIM" >/dev/null
check_gone   "stale qcow2 removed" "$DISK_RECLAIM_TMP/emulator-stale.qcow2"
check_exists "fresh qcow2 kept" "$DISK_RECLAIM_TMP/emulator-fresh.qcow2"
check_exists "non-emulator file in scratch dir untouched" "$DISK_RECLAIM_TMP/other-stale.bin"
check_gone   "old flutter_build cache removed" "$R/native/.dart_tool/flutter_build/old"
check_exists "recent flutter_build cache kept" "$R/native/.dart_tool/flutter_build/new"
check_gone   "merged worktree build output removed" "$R/.claude/worktrees/agent-merged/native/build"
check_gone   "merged worktree .dart_tool removed" "$R/.claude/worktrees/agent-merged/native/.dart_tool"
check_exists "merged worktree itself kept" "$R/.claude/worktrees/agent-merged/.git"
check_exists "unmerged worktree build output kept" "$R/.claude/worktrees/agent-open/native/build"
check_exists "unmerged worktree .dart_tool kept" "$R/.claude/worktrees/agent-open/native/.dart_tool"

# 3. --max-age-days 0 escalation takes the 1-day-old cache but not today's.
touch -d '2 days ago' "$R/native/.dart_tool/flutter_build/new"
mkdir -p "$R/native/.dart_tool/flutter_build/today"
"$RECLAIM" --max-age-days 0 >/dev/null
check_gone   "escalation removes the 2-day-old cache" "$R/native/.dart_tool/flutter_build/new"
check_exists "escalation keeps today's cache" "$R/native/.dart_tool/flutter_build/today"

# 4. disk-guard: silent above the floor, fails loud when nothing can be freed.
source "${REPO_ROOT}/scripts/lib/disk-guard.sh"
if out=$(DISK_GUARD_SOFT_G=0 DISK_GUARD_PATH="$SANDBOX" disk_guard t 2>&1) && [[ -z "$out" ]]; then
  ok "disk_guard is silent above the soft floor"
else
  bad "disk_guard above the floor: rc or output ($out)"
fi
if DISK_GUARD_SOFT_G=999999 DISK_GUARD_HARD_G=999999 DISK_GUARD_PATH="$SANDBOX" disk_guard t 2>/dev/null; then
  bad "disk_guard should fail when the hard floor is unreachable"
else
  ok "disk_guard fails loud below the hard floor"
fi
if DISK_GUARD_SOFT_G=999999 DISK_GUARD_HARD_G=999999 DISK_GUARD_SKIP=1 disk_guard t 2>/dev/null; then
  ok "DISK_GUARD_SKIP bypasses the guard"
else
  bad "DISK_GUARD_SKIP did not bypass"
fi

echo "disk-reclaim: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
