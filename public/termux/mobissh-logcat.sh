#!/data/data/com.termux/files/usr/bin/bash
# MobiSSH crash-log uploader for Termux.
#
# Without args : one-shot. Grab recent logcat, POST to the bridge, save local copy.
# --watch      : stream logcat, auto-upload on every FATAL entry. Ctrl-C to exit.
#
# Requires `adb` (pkg install android-tools) and a paired+connected ADB session.
# See https://mobissh.tailbe5094.ts.net/termux/README.md for setup.

set -euo pipefail

ENDPOINT="${MOBISSH_CRASH_ENDPOINT:-https://mobissh.tailbe5094.ts.net/api/native-crash}"
PACKAGE="${MOBISSH_PKG:-com.flavordrake.mobissh}"
LINES="${MOBISSH_CRASH_LINES:-5000}"
DEBOUNCE_S="${MOBISSH_CRASH_DEBOUNCE:-10}"
OUT_DIR="${HOME:-/data/data/com.termux/files/home}/mobissh-crash"

mode="once"
case "${1:-}" in
  --watch|-w) mode="watch" ;;
  --help|-h)
    sed -n '2,12p' "$0"
    exit 0
    ;;
esac

mkdir -p "$OUT_DIR"

# Sanity: adb installed?
if ! command -v adb >/dev/null 2>&1; then
  echo "adb not installed. Run: pkg install -y android-tools" >&2
  exit 1
fi

# Sanity: a device connected?
if ! adb devices | awk 'NR>1 && $2=="device" {found=1} END {exit !found}'; then
  echo "No ADB device. Pair + connect via Wireless debugging." >&2
  echo "See: https://mobissh.tailbe5094.ts.net/termux/README.md" >&2
  exit 2
fi

upload_bundle() {
  local trigger="${1:-one-shot}"
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local log="$OUT_DIR/$ts-logcat.txt"

  adb shell "logcat -d -t $LINES -b main -b crash -b system" > "$log" 2>&1 || true

  if [ ! -s "$log" ]; then
    echo "[$ts] logcat returned no output" >&2
    return 1
  fi

  local manufacturer model androidver sdk abi
  manufacturer="$(adb shell getprop ro.product.manufacturer | tr -d '\r')"
  model="$(adb shell getprop ro.product.model | tr -d '\r')"
  androidver="$(adb shell getprop ro.build.version.release | tr -d '\r')"
  sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
  abi="$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"

  {
    echo "=== mobissh crash bundle ==="
    echo "ts:          $ts"
    echo "trigger:     $trigger"
    echo "package:     $PACKAGE"
    echo "device:      $manufacturer $model"
    echo "androidVer:  $androidver"
    echo "sdk:         $sdk"
    echo "abi:         $abi"
    echo "logcat-bytes: $(wc -c < "$log")"
    echo "=== logcat ==="
    cat "$log"
  } | curl --max-time 30 --fail -sS -X POST \
        -H "Content-Type: text/plain" \
        --data-binary @- \
        "$ENDPOINT" \
    && echo "[$ts] uploaded — local copy: $log" \
    || { echo "[$ts] upload FAILED — local copy: $log" >&2; return 3; }
}

case "$mode" in
  once)
    upload_bundle "one-shot"
    ;;

  watch)
    echo "watching logcat for FATAL crashes... (Ctrl-C to stop)"
    echo "endpoint: $ENDPOINT"
    echo "out:      $OUT_DIR"
    echo
    last=0
    # Stream FATAL + Error level from main/crash/system; debounce to one upload per N s
    adb shell "logcat -b crash -b main -b system *:E" | while IFS= read -r line; do
      echo "  $line"
      if echo "$line" | grep -qE "AndroidRuntime: FATAL|libc.*Fatal signal|tombstoned"; then
        now=$(date +%s)
        if [ $((now - last)) -lt "$DEBOUNCE_S" ]; then continue; fi
        last=$now
        upload_bundle "$line" || true
      fi
    done
    ;;
esac
