#!/usr/bin/env bash
# scripts/deep-link-acceptance.sh — Real `am start` delivery of a mobissh:// link
# on the emulator (#1142, PR D of #1117; docs/deep-link-intents.md §12 A7–A10).
#
# The on-device flutter test (integration_test/deep_link_1117_test.dart) drives
# the router through the injectable link seam; it cannot issue an Android VIEW
# intent. This script covers the OS half with the real intent filter:
#   COLD  force-stop, `am start -a VIEW -d <link>` → no FATAL/ANR, mobissh on
#         top, a redacted `ui.link` ctrace line (never the raw link), screenshot.
#   WARM  app foregrounded, `am start` again → same assertions, second screenshot.
#   A10   R20 probe: launch the link FROM a stub caller task (Settings), press
#         Back, report which activity is on top. Reported, NOT gated — it is a
#         design input for whether `return=<uri>` is needed.
#
# Usage: scripts/deep-link-acceptance.sh [--apk PATH] [--link URI] [--device SERIAL] [--keep]
#   --apk PATH     APK to install (default: native/build/app/outputs/flutter-apk/app-debug.apk)
#                  Must be an APP build (`flutter-cmd.sh --in native build apk --debug`).
#                  The app-debug.apk left behind by `flutter test integration_test/…`
#                  has the TEST as its Dart entrypoint and never leaves the splash
#                  when launched by `am start` (observed: 60s+ on the splash, no
#                  `[CONNECT]` line in logcat).
#   --link URI     link to deliver (default: mobissh://connect?host=127.0.0.1&port=2222&user=testuser)
#   --device       adb serial (default: EMU_ADBD_ENDPOINT in connect mode, else first online device)
#   --keep         leave the app installed
#
# Emulator transport mirrors native-connect-test.sh: ADB_MODE=connect (default)
# does `adb connect $EMU_ADBD_ENDPOINT` (mobissh-emulator:5556, or the endpoint
# scripts/with-fleet-emulator.sh exports for a leased device).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/deep-link-acceptance.log"
exec > >(tee -a "$LOGFILE") 2>&1

APK="${REPO_ROOT}/native/build/app/outputs/flutter-apk/app-debug.apk"
LINK="mobissh://connect?host=127.0.0.1&port=2222&user=testuser"
DEVICE=""
KEEP=0
PACKAGE="com.flavordrake.mobissh"
ARTIFACTS_DIR="${REPO_ROOT}/test-results/deep-link-acceptance"
ADB_MODE="${ADB_MODE:-connect}"
EMU_CONTAINER_NAME="${EMU_CONTAINER_NAME:-mobissh-emulator}"
EMU_ADBD_ENDPOINT="${EMU_ADBD_ENDPOINT:-${EMU_CONTAINER_NAME}:5556}"
STUB_CALLER="com.android.settings/.Settings"
LINK_WAIT_SECS="${LINK_WAIT_SECS:-60}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apk) APK="$2"; shift 2 ;;
    --link) LINK="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "! unknown option: $1" >&2; exit 2 ;;
  esac
done

TS="$(date +%Y%m%dT%H%M%S%z)"
mkdir -p "$ARTIFACTS_DIR"
LOGCAT_FILE="${ARTIFACTS_DIR}/logcat-${TS}.txt"

log() { echo "> $*"; }
fail() { echo "! $*" >&2; exit 1; }

[[ -f "$APK" ]] || fail "APK not found: $APK (build: scripts/flutter-cmd.sh --in native build apk --debug)"
command -v adb >/dev/null 2>&1 || fail "adb not on PATH"

if [[ -z "$DEVICE" ]]; then
  if [[ "$ADB_MODE" == "connect" ]]; then
    log "adb connect ${EMU_ADBD_ENDPOINT}"
    secs=0
    while (( secs < 60 )); do
      adb connect "$EMU_ADBD_ENDPOINT" >/dev/null 2>&1 || true
      if adb -s "$EMU_ADBD_ENDPOINT" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -q 1; then
        DEVICE="$EMU_ADBD_ENDPOINT"
        break
      fi
      sleep 2; secs=$((secs + 2))
    done
  else
    DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  fi
fi
[[ -n "$DEVICE" ]] || fail "no online adb device (ADB_MODE=$ADB_MODE endpoint=$EMU_ADBD_ENDPOINT)"
ADB=(adb -s "$DEVICE")

log "device: $DEVICE"
log "apk:    $APK"
log "link:   $LINK"

if "${ADB[@]}" shell pm list packages | tr -d '\r' | grep -q "^package:${PACKAGE}$"; then
  log "uninstalling prior install..."
  "${ADB[@]}" uninstall "$PACKAGE" >/dev/null || true
fi
log "installing APK..."
"${ADB[@]}" install -r "$APK" >/dev/null || fail "adb install failed"
"${ADB[@]}" shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS 2>/dev/null || true

FAILED=0

top_activity() {
  "${ADB[@]}" shell dumpsys activity activities | tr -d '\r' \
    | awk '/topResumedActivity|mResumedActivity|ResumedActivity:/ {print; exit}'
}

# A cold debug APK sits on the splash for 10-20s on the emulator (Dart main
# has not run yet), so poll for the router's ctrace line instead of a fixed
# sleep. $1 = phase label, $2 = logcat dump path (left holding the last dump).
# A FATAL/ANR ends the wait early; the caller's assertions read the dump.
wait_for_link_line() {
  local phase="$1" dump="$2" waited=0
  while true; do
    "${ADB[@]}" logcat -d > "$dump"
    if grep -F '[ui.link]' "$dump" >/dev/null; then break; fi
    if grep -E "FATAL EXCEPTION.*${PACKAGE}|ANR in ${PACKAGE}" "$dump" >/dev/null; then break; fi
    if (( waited >= LINK_WAIT_SECS )); then break; fi
    sleep 2
    waited=$((waited + 2))
  done
  log "[$phase] settled after ${waited}s"
}

# One delivery phase: send the VIEW intent, wait, then assert crash-free,
# foregrounded, and a redacted ui.link line. $1 = phase label.
deliver_and_check() {
  local phase="$1"
  local shot="${ARTIFACTS_DIR}/${phase}-${TS}.png"
  "${ADB[@]}" logcat -c
  log "[$phase] am start -a android.intent.action.VIEW -d '$LINK'"
  "${ADB[@]}" shell am start -a android.intent.action.VIEW -d "'$LINK'" \
    || { echo "! [$phase] am start failed (no activity handles mobissh://?)"; FAILED=1; return; }
  wait_for_link_line "$phase" "$LOGCAT_FILE.$phase"
  "${ADB[@]}" exec-out screencap -p > "$shot" || true
  log "[$phase] screenshot: $shot"

  if grep -E "FATAL EXCEPTION.*${PACKAGE}|AndroidRuntime: Process: ${PACKAGE}|ANR in ${PACKAGE}" "$LOGCAT_FILE.$phase" >/dev/null; then
    echo "! [$phase] FATAL/ANR in logcat:"
    grep -E "FATAL EXCEPTION.*${PACKAGE}|AndroidRuntime: Process: ${PACKAGE}|ANR in ${PACKAGE}" -A 15 "$LOGCAT_FILE.$phase" | head -40
    FAILED=1
  else
    log "[$phase] no FATAL/ANR"
  fi

  local front
  front="$(top_activity)"
  log "[$phase] top: ${front:-<none>}"
  case "$front" in
    *"$PACKAGE"*) log "[$phase] mobissh foregrounded" ;;
    *) echo "! [$phase] mobissh is NOT the resumed activity"; FAILED=1 ;;
  esac

  # ctrace lines reach logcat as `[CONNECT][ui.link] ...` (debugPrint). R27:
  # the line carries the parsed verb / route / reason, never the link text.
  local lines
  lines="$(grep -F '[ui.link]' "$LOGCAT_FILE.$phase" || true)"
  if [[ -z "$lines" ]]; then
    echo "! [$phase] no ui.link ctrace line in logcat"
    FAILED=1
  else
    log "[$phase] ui.link lines:"
    printf '%s\n' "$lines" | sed 's/^/    /'
    if printf '%s\n' "$lines" | grep -F -- "$LINK" >/dev/null; then
      echo "! [$phase] ui.link line contains the RAW link text (R27 redaction violated)"
      FAILED=1
    else
      log "[$phase] ui.link lines are redacted (no raw link text)"
    fi
  fi
}

# COLD: force-stop first so the intent creates the task and app_links replays
# it as the initial link.
"${ADB[@]}" shell am force-stop "$PACKAGE"
sleep 1
deliver_and_check cold

# WARM: mobissh is foregrounded from the cold phase; deliver again (onNewIntent).
deliver_and_check warm

# A10 / R20: link launched FROM a stub caller task, then Back. `am start` from
# the shell has no caller task, so foreground Settings first; the VIEW intent
# then lands on top of that task the way a caller app's launch would.
log "[a10] stub caller: $STUB_CALLER"
"${ADB[@]}" shell am force-stop "$PACKAGE"
"${ADB[@]}" shell am start -n "$STUB_CALLER" >/dev/null 2>&1 || log "[a10] could not start $STUB_CALLER"
sleep 3
"${ADB[@]}" logcat -c
"${ADB[@]}" shell am start -a android.intent.action.VIEW -d "'$LINK'" >/dev/null 2>&1 || true
wait_for_link_line a10 "$LOGCAT_FILE.a10"
log "[a10] top after link: $(top_activity)"
"${ADB[@]}" exec-out screencap -p > "${ARTIFACTS_DIR}/a10-before-back-${TS}.png" || true
"${ADB[@]}" shell input keyevent KEYCODE_BACK
sleep 3
A10_TOP="$(top_activity)"
"${ADB[@]}" exec-out screencap -p > "${ARTIFACTS_DIR}/a10-after-back-${TS}.png" || true
log "[a10] top after Back: ${A10_TOP:-<none>}"
case "$A10_TOP" in
  *com.android.settings*) echo "A10: returned-to-caller=YES (top: $A10_TOP)" ;;
  *) echo "A10: returned-to-caller=NO (top: ${A10_TOP:-<none>})" ;;
esac

if [[ "$KEEP" -eq 0 ]]; then
  "${ADB[@]}" uninstall "$PACKAGE" >/dev/null || true
fi

log "artifacts: $ARTIFACTS_DIR (logcat-${TS}.txt.cold/.warm, screenshots)"
if [[ "$FAILED" -ne 0 ]]; then
  echo "! DEEP-LINK ACCEPTANCE FAILED"
  exit 1
fi
echo "+ DEEP-LINK ACCEPTANCE PASSED (cold + warm: no crash, foregrounded, redacted ui.link)"
