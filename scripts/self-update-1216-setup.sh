#!/usr/bin/env bash
# scripts/self-update-1216-setup.sh — fixture for
# native/integration_test/self_update_1216_test.dart (#1216).
#
# The accepted path must reach the SYSTEM INSTALLER, which needs "install
# unknown apps" (REQUEST_INSTALL_PACKAGES appop) granted to the debug app. A
# test cannot tap that settings toggle, and the app is (re)installed by the
# runner AFTER this setup runs, so — like native-connect-test.sh's
# POST_NOTIFICATIONS watcher — a bounded background loop re-grants it until the
# teardown stops it (or MAX_SECONDS passes, so an orphan cannot run forever).
#
# Also records the resumed activity after the test (teardown) as evidence that
# the hand-off reached the package installer.
set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
PIDFILE="${MOBISSH_TMPDIR}/self-update-1216-granter.pid"
PKG="com.flavordrake.mobissh"
MAX_SECONDS="${SELF_UPDATE_GRANT_MAX_SECONDS:-2400}"

if [[ -n "${EMU_ADBD_ENDPOINT:-}" ]]; then
  adb connect "$EMU_ADBD_ENDPOINT" || true
  DEVICE="$EMU_ADBD_ENDPOINT"
else
  DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
if [[ -z "$DEVICE" ]]; then
  echo "! self-update-1216-setup: no adb device" >&2
  exit 1
fi
echo "> self-update-1216-setup: granting REQUEST_INSTALL_PACKAGES to ${PKG} on ${DEVICE} (loop, <= ${MAX_SECONDS}s)"

if [[ -f "$PIDFILE" ]]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
fi

EVIDENCE="${MOBISSH_LOGDIR}/self-update-1216-installer.log"
SHOT="${MOBISSH_LOGDIR}/self-update-1216-installer.png"
rm -f "$EVIDENCE" "$SHOT"

# The same loop records the installer screen WHILE the test is live: by
# teardown time the runner has stopped the app and the installer is gone.
(
  end=$(( $(date +%s) + MAX_SECONDS ))
  while (( $(date +%s) < end )); do
    adb -s "$DEVICE" shell appops set "$PKG" REQUEST_INSTALL_PACKAGES allow >/dev/null 2>&1 || true
    if [[ ! -f "$SHOT" ]]; then
      top="$(adb -s "$DEVICE" shell dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity || true)"
      if [[ "$top" == *packageinstaller* ]]; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${top}" >"$EVIDENCE"
        adb -s "$DEVICE" exec-out screencap -p >"$SHOT" || true
      fi
    fi
    sleep 1
  done
) </dev/null >/dev/null 2>&1 &
echo $! >"$PIDFILE"
echo "> granter pid $(cat "$PIDFILE")"
