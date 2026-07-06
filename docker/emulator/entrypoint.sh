#!/usr/bin/env bash
# docker/emulator/entrypoint.sh — PID 1 of the mobissh-emulator container.
#
# Boots the AVD headless, exposes adb + the test-sshd bridge over the mobissh
# Docker network, waits for the guest to finish booting, then blocks so the
# container stays alive. Handles SIGTERM so `docker stop`/`restart` is clean.
#
# What it wires up (all reachable by other siblings via Docker DNS
# `mobissh-emulator`, since this environment has no docker-proxy / host -p):
#   :5037  adb server on ALL interfaces  → remote clients (fd-dev) can
#          `ANDROID_ADB_SERVER_SOCKET=tcp:mobissh-emulator:5037 adb devices`.
#   :5556  the emulator's own adbd (guest 5555), socat-exposed on a SEPARATE
#          port → a client running its OWN adb server can
#          `adb connect mobissh-emulator:5556` (this path keeps `adb forward`
#          LOCAL to the client, which flutter integration tests need — see
#          scripts/native-connect-test.sh). NOTE: the socat MUST NOT listen on
#          5555 itself — the emulator binds 127.0.0.1:5555 for adbd and a
#          0.0.0.0:5555 socat collides with it (0.0.0.0 covers loopback),
#          starving adbd so no device ever registers. Hence a distinct 5556.
#   :2222  socat → test-sshd:22, so the guest's `adb reverse tcp:2222` (set up
#          against the REMOTE adb server) lands on a real SSH target.
set -euo pipefail

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
ADB="${ANDROID_SDK_ROOT}/platform-tools/adb"
EMU="${ANDROID_SDK_ROOT}/emulator/emulator"
AVD="${AVD:-MobiSSH_Pixel7}"
EMU_MEMORY_MB="${EMU_MEMORY_MB:-6144}"
EMU_GPU="${EMU_GPU:-swiftshader_indirect}"
EMU_CORES="${EMU_CORES:-}"
SSHD_HOST="${SSHD_HOST:-test-sshd}"
SSHD_PORT="${SSHD_PORT:-22}"
BRIDGE_PORT="${BRIDGE_PORT:-2222}"
CONSOLE_PORT="${CONSOLE_PORT:-5554}"
ADBD_PORT="${ADBD_PORT:-5555}"
# The emulator binds 127.0.0.1:${ADBD_PORT} for adbd; expose it to the network on
# a DIFFERENT port so the socat listener can't collide with that bind.
ADBD_EXPOSE_PORT="${ADBD_EXPOSE_PORT:-5556}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"

log() { echo "> [emu-entrypoint] $*"; }
err() { echo "! [emu-entrypoint] $*" >&2; }

EMU_PID=""
ADB_SERVER_PID=""
SOCAT_SSHD_PID=""
SOCAT_ADBD_PID=""
XORG_PID=""

shutdown() {
  log "SIGTERM/EXIT — shutting down cleanly"
  [[ -n "$XORG_PID" ]] && kill "$XORG_PID" 2>/dev/null || true
  # Ask the emulator to power off via its adb server (graceful), then fall back
  # to a signal. This is what stops qemu leaving stale locks in the AVD.
  "$ADB" emu kill >/dev/null 2>&1 || true
  [[ -n "$EMU_PID" ]] && kill "$EMU_PID" 2>/dev/null || true
  [[ -n "$SOCAT_SSHD_PID" ]] && kill "$SOCAT_SSHD_PID" 2>/dev/null || true
  [[ -n "$SOCAT_ADBD_PID" ]] && kill "$SOCAT_ADBD_PID" 2>/dev/null || true
  "$ADB" kill-server >/dev/null 2>&1 || true
  [[ -n "$ADB_SERVER_PID" ]] && kill "$ADB_SERVER_PID" 2>/dev/null || true
  exit 0
}
trap shutdown SIGTERM SIGINT

# A crashed prior run (before a `docker restart`) can leave AVD locks that block
# a fresh boot ("Running multiple emulators with the same AVD"). Clear them.
clear_stale() {
  rm -f "${ANDROID_AVD_HOME:-/root/.android/avd}/${AVD}.avd/multiinstance.lock" \
        "${ANDROID_AVD_HOME:-/root/.android/avd}/${AVD}.avd/hardware-qemu.ini.lock" 2>/dev/null || true
  rm -rf "${ANDROID_AVD_HOME:-/root/.android/avd}/running" 2>/dev/null || true
}

# 0. Headless Xorg for the `-gpu host` path. The android emulator's host GL
#    renderer is GLX (X11) on Linux — it needs a DISPLAY. Surfaceless EGL does
#    NOT satisfy it. So stand up a real (but monitorless) Xorg on the iGPU via
#    the modesetting driver + a Virtual framebuffer, and point the emulator at
#    it with DISPLAY=:0. glxinfo's renderer string is the hardware-GL verdict.
start_xorg() {
  log "EMU_GPU=host → starting headless Xorg :0 on the iGPU (/dev/dri/card1)"
  Xorg :0 -noreset -config /etc/X11/xorg-headless.conf -logfile /tmp/xorg.log vt1 &
  XORG_PID=$!
  export DISPLAY=:0
  local s=0
  while (( s < 15 )); do
    if DISPLAY=:0 xdpyinfo >/dev/null 2>&1; then log "Xorg :0 is up"; break; fi
    if ! kill -0 "$XORG_PID" 2>/dev/null; then
      err "Xorg exited during startup — dumping /tmp/xorg.log:"
      cat /tmp/xorg.log 2>/dev/null | tail -30 || true
      return 1
    fi
    sleep 1; s=$((s + 1))
  done
  local glr
  glr="$(DISPLAY=:0 glxinfo 2>/dev/null | grep -iE 'OpenGL renderer' | head -1 | tr -d '\r' || true)"
  if [[ -n "$glr" ]]; then
    log "$glr"
    if echo "$glr" | grep -qiE 'llvmpipe|softpipe|software rasterizer'; then
      err "GLX is SOFTWARE (llvmpipe) — Xorg came up but NOT on the iGPU"
    elif echo "$glr" | grep -qiE 'intel|mesa'; then
      log "headless hardware GLX CONFIRMED on the iGPU"
    fi
  else
    err "glxinfo produced no renderer — GLX not ready (see /tmp/xorg.log)"
  fi
  return 0
}

# 1. adb server on ALL interfaces (0.0.0.0:5037). `-a nodaemon server` is the
#    documented way to bind every interface; background it and keep the PID.
start_adb_server() {
  log "starting adb server on all interfaces (:5037)"
  "$ADB" -a -P 5037 nodaemon server &
  ADB_SERVER_PID=$!
  # Give it a moment to bind before the emulator tries to register.
  local s=0
  while (( s < 10 )); do
    if "$ADB" version >/dev/null 2>&1; then return 0; fi
    sleep 1; s=$((s + 1))
  done
  return 0
}

# 2. Boot the emulator headless. -read-only lets a crashed instance's userdata
#    overlay be thrown away on restart (clean recovery). Deterministic ports so
#    the :5555 adbd socat below has a fixed target.
boot_emulator() {
  clear_stale
  local flags=(-avd "$AVD" -ports "${CONSOLE_PORT},${ADBD_PORT}" \
    -no-window -no-audio -no-boot-anim -no-snapshot \
    -memory "$EMU_MEMORY_MB" -gpu "$EMU_GPU" -accel auto -read-only)
  local pin=()
  if [[ -n "$EMU_CORES" ]] && command -v taskset >/dev/null 2>&1; then
    pin=(taskset -c "$EMU_CORES")
    log "CPU-pinning emulator to cores $EMU_CORES"
  fi
  log "booting $AVD (gpu=$EMU_GPU, ${EMU_MEMORY_MB}MB) headless"
  "${pin[@]}" "$EMU" "${flags[@]}" &
  EMU_PID=$!
  log "emulator pid $EMU_PID"
}

# 3. socat bridges. test-sshd:22 for the guest reverse-tunnel target; the guest
#    adbd exposed to the network for the `adb connect` client path.
start_bridges() {
  log "socat 0.0.0.0:${BRIDGE_PORT} → ${SSHD_HOST}:${SSHD_PORT} (test-sshd bridge)"
  socat "TCP-LISTEN:${BRIDGE_PORT},fork,reuseaddr" "TCP:${SSHD_HOST}:${SSHD_PORT}" &
  SOCAT_SSHD_PID=$!
  log "socat 0.0.0.0:${ADBD_EXPOSE_PORT} → 127.0.0.1:${ADBD_PORT} (expose guest adbd)"
  socat "TCP-LISTEN:${ADBD_EXPOSE_PORT},fork,reuseaddr" "TCP:127.0.0.1:${ADBD_PORT}" &
  SOCAT_ADBD_PID=$!
}

wait_booted() {
  log "waiting for sys.boot_completed (<= ${BOOT_TIMEOUT}s)"
  "$ADB" wait-for-device 2>/dev/null || true
  local s=0 b
  while (( s < BOOT_TIMEOUT )); do
    b="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$b" == "1" ]]; then
      log "BOOTED — sys.boot_completed=1"
      "$ADB" devices || true
      return 0
    fi
    sleep 3; s=$((s + 3))
  done
  err "guest did not finish booting within ${BOOT_TIMEOUT}s"
  return 1
}

# After boot, log the ACTUAL GL renderer so `docker logs` states plainly whether
# we got hardware GL (iGPU) or fell back to software. The emulator translates
# guest GLES to host GL, so the guest's renderer string embeds the host renderer:
#   host GL   → "Android Emulator OpenGL ES Translator (Mesa Intel(R) ...)"
#   software  → "Android Emulator OpenGL ES Translator (Google SwiftShader)"
probe_gpu() {
  log "GPU mode requested: EMU_GPU=$EMU_GPU"
  if [[ -e /dev/dri/renderD128 ]]; then
    log "/dev/dri present in container: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
  else
    err "/dev/dri NOT present — hardware GL unavailable, expect software fallback"
  fi
  local r
  r="$("$ADB" shell dumpsys SurfaceFlinger 2>/dev/null | grep -iE 'GLES:|renderer' | head -1 | tr -d '\r' || true)"
  [[ -n "$r" ]] && log "guest GL renderer → $r"
  if echo "$r" | grep -qi swiftshader; then
    err "GL renderer is SwiftShader (software) — hardware GL did NOT engage"
  elif echo "$r" | grep -qiE 'intel|mesa'; then
    log "hardware GL CONFIRMED (Intel/Mesa via the iGPU)"
  fi
}

# After boot, force the animation scales ON so the soft-keyboard (IME) inset
# ANIMATES on show/hide instead of snapping. WHY (#971): this AVD ships with
# `animator_duration_scale` UNSET, and on this system image an unset value
# resolves to 0 (animations off) — so the IME inset jumps 0 → full in a single
# frame. The InsetsController's IME show/hide animation is timed by the animator
# duration scale (NOT window/transition scale), so an explicit 1.0 is what makes
# `WindowInsets`/`viewInsets.bottom` transition over ~200-300ms (~14 rendered
# frames at 60Hz), letting integration tests stage a keyboard-animation resize
# race. Re-applied every boot because the container runs `-read-only`: global
# settings live in the throwaway /data overlay and are lost on restart.
enable_ime_animation() {
  log "forcing animation scales ON (IME inset must animate, not snap — #971)"
  "$ADB" shell settings put global window_animation_scale 1.0 || true
  "$ADB" shell settings put global transition_animation_scale 1.0 || true
  "$ADB" shell settings put global animator_duration_scale 1.0 || true
  local a
  a="$("$ADB" shell settings get global animator_duration_scale 2>/dev/null | tr -d '\r' || true)"
  log "animator_duration_scale now = ${a:-unknown} (1.0 = IME slide animates)"
}

start_adb_server
if [[ "$EMU_GPU" == "host" ]]; then
  start_xorg || err "Xorg startup failed — -gpu host will fail; surfacing emulator error"
fi
boot_emulator
start_bridges
if ! wait_booted; then
  err "boot failed — dumping emulator status; container will stay up for inspection"
  "$ADB" devices || true
else
  probe_gpu
  enable_ime_animation
fi

log "emulator container ready — blocking on emulator process (pid $EMU_PID)"
# Block on the emulator so the container's lifecycle tracks it, but keep the
# trap responsive: `wait` returns when a trapped signal fires.
while kill -0 "$EMU_PID" 2>/dev/null; do
  wait "$EMU_PID" || true
done
err "emulator process exited — container will exit (compose restart policy recovers it)"
