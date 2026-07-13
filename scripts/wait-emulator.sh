#!/usr/bin/env bash
# scripts/wait-emulator.sh — block until the emulator is attached AND Android
# has finished booting (sys.boot_completed=1), then exit 0. Companion to
# boot-emulator.sh (which launches the AVD). Avoids the recurring inline
# `adb wait-for-device` + `adb shell 'while … boot_completed …'` compound.
#
# Usage: scripts/wait-emulator.sh [timeout-seconds]   (default 240)
set -euo pipefail

ADB="${ANDROID_SDK_ROOT:-/opt/android-sdk}/platform-tools/adb"
DEADLINE_S="${1:-240}"

echo "> waiting for emulator to attach (<= ${DEADLINE_S}s)"
timeout "$DEADLINE_S" "$ADB" wait-for-device

echo "> waiting for sys.boot_completed"
# Poll on-device; the loop runs inside one adb shell so it's a single command.
timeout "$DEADLINE_S" "$ADB" shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done; echo BOOTED'
echo "+ emulator booted + ready"
