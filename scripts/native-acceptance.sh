#!/usr/bin/env bash
# scripts/native-acceptance.sh — Install + first-run smoke for the native APK
#
# Catches the class of silent launch-crash bugs that the unit-test gate can't
# see — e.g. AndroidManifest activity name resolving against applicationId
# (see memory: reference_android_manifest_class_fqn.md, #501 history).
#
# Steps:
#   1. Resolve emulator device serial
#   2. Uninstall any prior install (true first-run state)
#   3. Install the APK
#   4. Clear logcat + launch the launcher activity
#   5. Wait for first frame
#   6. Verify our activity is actually foregrounded
#   7. Scan logcat for FATAL EXCEPTION / ANR / AndroidRuntime errors
#   8. Capture a screenshot artifact
#
# Usage: scripts/native-acceptance.sh [--apk PATH] [--device SERIAL] [--keep]
#   --apk PATH        APK to install (default: public/mobissh-native.apk)
#   --device SERIAL   adb device serial (default: first online emulator)
#   --keep            don't uninstall the app at the end (leave it for inspection)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/native-acceptance.log"
exec > >(tee -a "$LOGFILE") 2>&1

APK="${REPO_ROOT}/public/mobissh-native.apk"
DEVICE=""
KEEP=0
PACKAGE="com.flavordrake.mobissh"
ARTIFACTS_DIR="${REPO_ROOT}/test-results/native-acceptance"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apk) APK="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "! unknown option: $1" >&2; exit 2 ;;
  esac
done

TS="$(date +%Y%m%dT%H%M%S%z)"
mkdir -p "$ARTIFACTS_DIR"
SCREENSHOT="${ARTIFACTS_DIR}/first-run-${TS}.png"
LOGCAT_FILE="${ARTIFACTS_DIR}/logcat-${TS}.txt"

log() { echo "> $*"; }
fail() { echo "! $*" >&2; exit 1; }

if [[ ! -f "$APK" ]]; then
  fail "APK not found: $APK"
fi

if ! command -v adb >/dev/null 2>&1; then
  fail "adb not on PATH — run scripts/setup-avd.sh first"
fi

# Resolve device serial: prefer first online emulator if not given.
if [[ -z "$DEVICE" ]]; then
  DEVICE="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  if [[ -z "$DEVICE" ]]; then
    fail "no online adb device — start an emulator (see scripts/setup-avd.sh)"
  fi
fi

ADB=(adb -s "$DEVICE")

# Make sure boot finished — needed when this runs right after `emulator -avd ...`.
if ! "${ADB[@]}" shell getprop sys.boot_completed | tr -d '\r\n' | grep -q '^1$'; then
  log "waiting for sys.boot_completed=1 on $DEVICE..."
  "${ADB[@]}" wait-for-device
  for _ in $(seq 1 60); do
    if "${ADB[@]}" shell getprop sys.boot_completed | tr -d '\r\n' | grep -q '^1$'; then
      break
    fi
    sleep 1
  done
fi

log "device: $DEVICE"
log "apk:    $APK"
log "pkg:    $PACKAGE"

# Uninstall to guarantee true first-run state (clean storage, no migrations).
if "${ADB[@]}" shell pm list packages | tr -d '\r' | grep -q "^package:${PACKAGE}$"; then
  log "uninstalling prior install..."
  "${ADB[@]}" uninstall "$PACKAGE" || true
fi

log "installing APK..."
if ! "${ADB[@]}" install -r "$APK"; then
  fail "adb install failed"
fi

# Resolve the launcher activity from the manifest so we don't hardcode the
# class name — that's the exact bug class we want to catch downstream, not
# encode in the smoke runner.
LAUNCHER="$("${ADB[@]}" shell cmd package resolve-activity --brief "$PACKAGE" \
  | tr -d '\r' | awk -F/ '/^[a-zA-Z0-9_.]+\// {print $1 "/" $2; exit}')"
if [[ -z "$LAUNCHER" ]]; then
  fail "could not resolve launcher activity for $PACKAGE"
fi
log "launcher: $LAUNCHER"

# Clear logcat ring so we only see this run's events.
"${ADB[@]}" logcat -c

# Launch via explicit component — using `monkey -p` works too but `am start`
# surfaces the activity-not-found error in stderr immediately, which is
# exactly the signal we want for the FQN-mismatch class of bug.
log "launching..."
if ! "${ADB[@]}" shell am start -n "$LAUNCHER" -a android.intent.action.MAIN -c android.intent.category.LAUNCHER; then
  fail "am start failed (launcher component invalid?)"
fi

# Give Flutter time to attach + render the first frame.
sleep 5

# Capture logcat once — we'll grep multiple things out of it.
"${ADB[@]}" logcat -d > "$LOGCAT_FILE"

# Foreground check: dumpsys activity activities must show our package on top.
FRONT="$("${ADB[@]}" shell dumpsys activity activities | tr -d '\r' | awk '/topResumedActivity|mResumedActivity|ResumedActivity:/ {print; exit}')"
log "topResumed: ${FRONT:-<none>}"

# Detect a launch-crash. The "Force Close" dialog logs an AndroidRuntime
# FATAL EXCEPTION; ANRs log "ANR in <pkg>". Activity-not-found is an
# ActivityManager warning; treat it as fatal because it's the bug class we
# care about most. (See memory: reference_android_manifest_class_fqn.md.)
FATAL=0
FATAL_LINES=""

if grep -E "FATAL EXCEPTION.*${PACKAGE}|AndroidRuntime: Process: ${PACKAGE}" "$LOGCAT_FILE" >/dev/null; then
  FATAL=1
  FATAL_LINES+=$'\n--- FATAL EXCEPTION ---\n'
  FATAL_LINES+="$(grep -E "FATAL EXCEPTION.*${PACKAGE}|AndroidRuntime: Process: ${PACKAGE}" -A 20 "$LOGCAT_FILE" | head -60)"
fi

if grep -E "ANR in ${PACKAGE}" "$LOGCAT_FILE" >/dev/null; then
  FATAL=1
  FATAL_LINES+=$'\n--- ANR ---\n'
  FATAL_LINES+="$(grep -E "ANR in ${PACKAGE}" -A 10 "$LOGCAT_FILE" | head -30)"
fi

if grep -E "Unable to find explicit activity class|ClassNotFoundException.*${PACKAGE}" "$LOGCAT_FILE" >/dev/null; then
  FATAL=1
  FATAL_LINES+=$'\n--- ACTIVITY/CLASS NOT FOUND ---\n'
  FATAL_LINES+="$(grep -E "Unable to find explicit activity class|ClassNotFoundException.*${PACKAGE}" -A 5 "$LOGCAT_FILE" | head -30)"
fi

# Capture a screenshot regardless — useful for both pass (what does first-run
# actually look like?) and fail (what's on screen when it crashed?).
"${ADB[@]}" exec-out screencap -p > "$SCREENSHOT" || true

# Foreground check: even without a FATAL, if our activity isn't on top after
# 5s the launch failed silently (e.g. activity registered but Flutter engine
# threw during attach).
case "$FRONT" in
  *"$PACKAGE"*) FOREGROUNDED=1 ;;
  *)            FOREGROUNDED=0 ;;
esac

log "artifacts:"
log "  logcat:     $LOGCAT_FILE"
log "  screenshot: $SCREENSHOT"

if [[ "$KEEP" -eq 0 ]]; then
  log "uninstalling (use --keep to leave the app installed)..."
  "${ADB[@]}" uninstall "$PACKAGE" || true
fi

if [[ "$FATAL" -eq 1 ]]; then
  echo "! NATIVE ACCEPTANCE FAILED — crash detected"
  printf '%s\n' "$FATAL_LINES"
  exit 1
fi

if [[ "$FOREGROUNDED" -ne 1 ]]; then
  echo "! NATIVE ACCEPTANCE FAILED — activity did not reach foreground"
  echo "  topResumed: ${FRONT:-<none>}"
  echo "  (screenshot captured at $SCREENSHOT — inspect for what's actually visible)"
  exit 1
fi

echo "+ NATIVE ACCEPTANCE PASSED (install + first-frame, no crash, foregrounded)"
