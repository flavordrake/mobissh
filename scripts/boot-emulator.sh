#!/usr/bin/env bash
# scripts/boot-emulator.sh — boot the MobiSSH AVD headless, directly via the
# emulator binary. setup-avd.sh's launch step hardcodes /home/dev/Android/Sdk
# (wrong — the SDK is /opt/android-sdk), so it can create/tune the AVD but can't
# launch it. This boots the already-created AVD and waits for sys.boot_completed.
#
# Usage: scripts/boot-emulator.sh [avd-name]   (default: MobiSSH_Pixel7)
# Run in the BACKGROUND (it execs the long-lived emulator process and blocks
# until killed); a separate `adb wait-for-device` confirms readiness.
set -euo pipefail

MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
EMULATOR_BIN="$ANDROID_SDK_ROOT/emulator/emulator"
AVD_NAME="${1:-MobiSSH_Pixel7}"

if [ ! -x "$EMULATOR_BIN" ]; then
  echo "! boot-emulator: emulator binary not found at $EMULATOR_BIN" >&2
  exit 2
fi

# OOM guard (#763): a leftover Gradle daemon can starve the emulator (exit 139).
if pgrep -f GradleDaemon >/dev/null 2>&1; then
  echo "> killing stray GradleDaemon to free memory before boot"
  pkill -f GradleDaemon || true
fi

# Idempotency: a surviving emulator from a prior run + this fresh boot = TWO
# emulators (~8G) → OOM on the 15G host, and `adb wait-for-device` errors with
# "more than one device". Kill any existing emulator-* first so we always end up
# with exactly one.
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
existing_emulators() { "$ADB" devices | grep -oE '^emulator-[0-9]+' || true; }
for dev in $(existing_emulators); do
  echo "> killing pre-existing $dev (avoid a second emulator → OOM)"
  "$ADB" -s "$dev" emu kill || true
done

echo "> booting AVD $AVD_NAME headless (sdk=$ANDROID_SDK_ROOT)"
exec "$EMULATOR_BIN" -avd "$AVD_NAME" \
  -no-window -no-audio -no-boot-anim -no-snapshot \
  -gpu swiftshader_indirect \
  -accel auto
