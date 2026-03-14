#!/usr/bin/env bash
# scripts/emulator-diag.sh — Diagnose emulator ↔ server connectivity
#
# Verifies the full chain: emulator → ADB reverse tunnel → server → test-sshd.
# Run this before emulator tests to catch networking issues early.
#
# Usage: scripts/emulator-diag.sh

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"

PORT="${PORT:-8081}"
# Emulator QEMU host gateway — maps to container's loopback.
# ADB reverse tunnels don't support WebSocket, so emulator must use this IP.
EMU_HOST="${EMU_HOST:-10.0.2.2}"
SSHD_HOST="${SSHD_HOST:-test-sshd}"
SSHD_PORT="${SSHD_PORT:-22}"
CDP_PORT="${CDP_PORT:-9222}"
EMU_SERIAL="${EMU_SERIAL:-emulator-5554}"

log() { echo "> $*"; }
ok()  { echo "+ $*"; }
err() { echo "! $*" >&2; }
fail() { err "$*"; FAILURES=$((FAILURES + 1)); }

FAILURES=0

# 1. ADB connection
log "Checking ADB connection to ${EMU_SERIAL}..."
if adb -s "$EMU_SERIAL" get-state 2>/dev/null | grep -q device; then
  ok "ADB connected to ${EMU_SERIAL}."
else
  fail "ADB cannot reach ${EMU_SERIAL}. Is the emulator running?"
fi

# 2. Local server
log "Checking MobiSSH server on port ${PORT}..."
if curl -sf --max-time 3 "http://localhost:${PORT}/" >/dev/null 2>&1; then
  ok "MobiSSH server responding on localhost:${PORT}."
else
  fail "MobiSSH server NOT responding on localhost:${PORT}."
  log "Start it: scripts/server-ctl.sh ensure"
fi

# 3. ADB reverse tunnel
log "Checking ADB reverse tunnel..."
REVERSE_LIST=$(adb -s "$EMU_SERIAL" reverse --list 2>/dev/null || true)
if echo "$REVERSE_LIST" | grep -q "tcp:${PORT}"; then
  ok "ADB reverse tunnel exists: tcp:${PORT} → tcp:${PORT}."
else
  log "No reverse tunnel for port ${PORT}. Creating..."
  adb -s "$EMU_SERIAL" reverse tcp:"${PORT}" tcp:"${PORT}"
  ok "ADB reverse tunnel created."
fi

# 4. Emulator → server via reverse tunnel (TCP)
log "Testing TCP from emulator to localhost:${PORT}..."
if adb -s "$EMU_SERIAL" shell "nc -w 2 localhost ${PORT}" </dev/null 2>/dev/null; then
  ok "TCP connection from emulator to localhost:${PORT} succeeded."
else
  fail "TCP connection from emulator to localhost:${PORT} FAILED."
  log "The reverse tunnel may not be routing correctly."
fi

# 5. Emulator → server via QEMU host gateway (10.0.2.2)
# ADB reverse tunnels don't support WebSocket. The emulator uses 10.0.2.2
# (QEMU host gateway) which maps to the container's loopback when the
# emulator process runs inside the container.
log "Testing emulator → server via ${EMU_HOST}:${PORT} (QEMU gateway)..."
EMU_PAGE_RESULT=$(node -e "
const { chromium } = require('@playwright/test');
(async () => {
  const b = await chromium.connectOverCDP('http://127.0.0.1:${CDP_PORT}');
  const ctx = b.contexts()[0];
  const page = await ctx.newPage();
  try {
    await page.goto('http://${EMU_HOST}:${PORT}', { waitUntil: 'domcontentloaded', timeout: 10000 });
    const title = await page.title();
    // Test WebSocket too
    const ws = await page.evaluate(() => {
      return new Promise(resolve => {
        const token = document.querySelector('meta[name=\"ws-token\"]')?.content || '';
        const ws = new WebSocket('ws://${EMU_HOST}:${PORT}/?token=' + encodeURIComponent(token));
        ws.onopen = () => { resolve('OK'); ws.close(); };
        ws.onerror = () => resolve('FAIL');
        setTimeout(() => resolve('TIMEOUT'), 5000);
      });
    });
    console.log('HTTP=' + title + ' WS=' + ws);
  } catch (e) { console.log('HTTP=FAIL WS=FAIL'); }
  await page.close().catch(() => {});
  b.close();
})();
" 2>/dev/null || echo "HTTP=FAIL WS=FAIL")
EMU_HTTP=$(echo "$EMU_PAGE_RESULT" | grep -oP 'HTTP=\K\S+')
EMU_WS=$(echo "$EMU_PAGE_RESULT" | grep -oP 'WS=\K\S+')
if [[ "$EMU_HTTP" == "MobiSSH" && "$EMU_WS" == "OK" ]]; then
  ok "Emulator HTTP + WebSocket via ${EMU_HOST}:${PORT} both work."
elif [[ "$EMU_HTTP" == "MobiSSH" ]]; then
  fail "Emulator HTTP works but WebSocket fails via ${EMU_HOST}:${PORT}."
else
  fail "Emulator cannot reach server via ${EMU_HOST}:${PORT}."
  log "Ensure the emulator process runs inside this container (pgrep qemu)."
fi

# 6. CDP forward
log "Checking CDP forward for Chrome DevTools..."
FORWARD_LIST=$(adb -s "$EMU_SERIAL" forward --list 2>/dev/null || true)
if echo "$FORWARD_LIST" | grep -q "tcp:${CDP_PORT}"; then
  ok "CDP forward exists: tcp:${CDP_PORT} → chrome_devtools_remote."
else
  log "No CDP forward. Creating..."
  adb -s "$EMU_SERIAL" forward tcp:"${CDP_PORT}" localabstract:chrome_devtools_remote
  ok "CDP forward created."
fi

# 7. CDP connectivity
log "Testing CDP connection on localhost:${CDP_PORT}..."
CDP_RESP=$(curl -sf --max-time 3 "http://127.0.0.1:${CDP_PORT}/json/version" 2>/dev/null || true)
if echo "$CDP_RESP" | grep -q "Browser"; then
  ok "CDP responding. Browser: $(echo "$CDP_RESP" | grep -oP '"Browser"\s*:\s*"\K[^"]+' || echo 'unknown')"
else
  fail "CDP NOT responding on localhost:${CDP_PORT}."
  log "Ensure Chrome is open on the emulator."
fi

# 8. Docker test-sshd
log "Checking test-sshd (${SSHD_HOST}:${SSHD_PORT})..."
if getent hosts "$SSHD_HOST" >/dev/null 2>&1; then
  SSHD_IP=$(getent hosts "$SSHD_HOST" | awk '{print $1}')
  ok "DNS resolves: ${SSHD_HOST} → ${SSHD_IP}."
  if nc -z -w 2 "$SSHD_HOST" "$SSHD_PORT" 2>/dev/null; then
    ok "SSH port open on ${SSHD_HOST}:${SSHD_PORT}."
  else
    fail "SSH port CLOSED on ${SSHD_HOST}:${SSHD_PORT}."
  fi
else
  fail "DNS cannot resolve ${SSHD_HOST}. Docker network may not be set up."
  log "Run: docker network create mobissh && docker network connect mobissh \$(hostname)"
fi

# 9. Server → test-sshd (the full path MobiSSH takes)
log "Testing SSH from this container to ${SSHD_HOST}:${SSHD_PORT}..."
KEY="/tmp/mobissh-test-sshd-key"
if [[ -f "$KEY" ]]; then
  SSH_OUT=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 \
    -i "$KEY" testuser@"$SSHD_HOST" -p "$SSHD_PORT" echo "SSH_OK" 2>/dev/null || true)
  if [[ "$SSH_OUT" == *"SSH_OK"* ]]; then
    ok "SSH from container to ${SSHD_HOST}:${SSHD_PORT} works."
  else
    fail "SSH connection to ${SSHD_HOST}:${SSHD_PORT} failed."
  fi
else
  log "SSH key not found at ${KEY}. Run test-sshd fixture first."
fi

# Summary
echo ""
if (( FAILURES == 0 )); then
  ok "All checks passed. Emulator test infrastructure is ready."
else
  err "${FAILURES} check(s) failed. Fix issues above before running emulator tests."
fi
exit "$FAILURES"
