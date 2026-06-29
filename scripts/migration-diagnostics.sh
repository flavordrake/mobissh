#!/usr/bin/env bash
# scripts/migration-diagnostics.sh — post-migration self-diagnostics, lowest level
# (highest reliability) → up. Run after the runtime container is moved to a new
# host to verify the environment came up intact. READ-ONLY: it reports health and
# never mutates state (restore actions like container-ctl.sh / test-sshd-up.sh are
# separate, deliberate steps). Exit 0 if every layer is PASS/WARN, 1 if any FAIL.
#
# Layers (each independent; a failure in one does NOT abort the rest):
#   0 identity + hardware   1 repo integrity      2 github remote/auth
#   3 cached bug uploads    4 toolchain present    5 docker services + network
#   6 KVM/emulator          (7 APK build is a separate heavy step — not run here)
#
# Usage: scripts/migration-diagnostics.sh
set -uo pipefail
cd "$(dirname "$0")/.."

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/migration-diagnostics.log"
exec > >(tee -a "$LOGFILE") 2>&1

FAILED=0
pass() { echo "  PASS  $1"; }
warn() { echo "  WARN  $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }

echo "== migration self-diagnostics @ $(date +%Y%m%dT%H%M%S%z) =="

echo "[0] identity + hardware"
echo "  host=$(hostname) cores=$(nproc) mem=$(free -g | awk '/^Mem:/{print $2"G total, "$7"G avail"}') disk=$(df -h / | awk 'NR==2{print $4" free ("$5" used)"}')"
pass "identity/hardware readable"

echo "[1] repo integrity"
if git rev-parse --git-dir >/dev/null 2>&1; then
  pass "git repo @ $(git rev-parse --short HEAD) ($(git log -1 --format=%s | cut -c1-60))"
else
  fail "not a git repo (CWD drift / missing checkout)"
fi

echo "[2] github remote + auth"
if git ls-remote --heads origin main >/dev/null 2>&1; then
  local_h="$(git rev-parse HEAD)"; remote_h="$(git ls-remote origin -h refs/heads/main | awk '{print $1}')"
  if [ "$local_h" = "$remote_h" ]; then pass "remote reachable; local==origin/main"; else warn "remote reachable but local != origin/main (ahead/behind)"; fi
else
  fail "cannot reach origin (network/auth)"
fi

echo "[3] cached bug-report uploads (the migration data test)"
UP=test-results/uploads
if [ -d "$UP" ]; then
  pngs=$(find "$UP" -type f -name '*.png' | wc -l)
  vids=$(find "$UP" -type f \( -name '*.mp4' -o -name '*.webm' -o -name '*.gif' \) | wc -l)
  sz=$(du -sh "$UP" | awk '{print $1}')
  if [ "$pngs" -gt 0 ]; then pass "$pngs screenshots, $vids videos, $sz total"; else warn "uploads dir present but no screenshots ($vids videos, $sz)"; fi
else
  warn "no uploads dir yet (fresh host / nothing uploaded)"
fi

echo "[4] toolchain present"
if command -v flutter >/dev/null 2>&1; then pass "flutter on PATH"; \
elif [ -x scripts/flutter-cmd.sh ]; then pass "flutter via scripts/flutter-cmd.sh"; \
else fail "flutter toolchain not found"; fi

echo "[5] docker services + network"
if docker info >/dev/null 2>&1; then
  net=$(docker network ls --filter name=mobissh --format '{{.Name}}' | head -1)
  [ -n "$net" ] && pass "docker network '$net' present" || warn "docker network 'mobissh' MISSING (recreate: container-ctl.sh / test-sshd-up.sh auto-create)"
  prod=$(docker ps --filter name=mobissh-prod --format '{{.Status}}' | head -1)
  [ -n "$prod" ] && pass "mobissh-prod up ($prod)" || warn "mobissh-prod DOWN — upload target offline (restore: scripts/container-ctl.sh ensure)"
  sshd=$(docker ps --filter name=test-sshd --format '{{.Status}}' | head -1)
  [ -n "$sshd" ] && pass "test-sshd up ($sshd)" || warn "test-sshd DOWN — integration tests blocked (restore: scripts/test-sshd-up.sh)"
else
  fail "docker daemon unreachable"
fi

echo "[6] KVM / emulator capability"
[ -e /dev/kvm ] && pass "/dev/kvm present" || warn "/dev/kvm missing — emulator cannot run"

echo "== summary: $([ "$FAILED" -eq 0 ] && echo 'OK (no hard failures)' || echo 'FAIL — see above') =="
echo "  next (deliberate, not run here): restore services (container-ctl.sh ensure, test-sshd-up.sh); APK build (native-release-apk.sh)"
exit "$FAILED"
