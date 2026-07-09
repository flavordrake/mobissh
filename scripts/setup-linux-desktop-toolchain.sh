#!/usr/bin/env bash
# scripts/setup-linux-desktop-toolchain.sh — install the GTK/clang toolchain
# Flutter needs to build the LINUX DESKTOP target in this container (#1012
# Phase 0). Used to validate the desktop flavor of the native app (direct
# dart:io SSH + in-process SessionHost, no Android foreground service) without
# a Mac — macOS desktop shares ~all of this code; only the final .app
# packaging needs a Mac.
#
# Also installs what the headless E2E loop needs (scripts/desktop-smoke.sh):
# xvfb for a virtual display and ffmpeg for x11grab screenshots.
#
# Idempotent. Requires passwordless sudo (confirmed in fd-dev).

set -euo pipefail

MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/setup-linux-desktop-toolchain.log"
exec > >(tee -a "$LOGFILE") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "> apt-get update"
sudo apt-get update -y

echo "> installing flutter linux-desktop toolchain + headless E2E deps"
# libsecret-1-dev: flutter_secure_storage_linux (credential vault) builds
# against libsecret. NOTE: at RUNTIME the vault also needs a Secret Service
# (gnome-keyring) — absent in a headless container; see desktop_smoke_test.dart.
# xvfb + ffmpeg: virtual display + x11grab screenshot for desktop-smoke.sh.
sudo apt-get install -y \
  clang \
  cmake \
  ninja-build \
  pkg-config \
  libgtk-3-dev \
  liblzma-dev \
  libsecret-1-dev \
  xvfb \
  ffmpeg

echo "> flutter config --enable-linux-desktop (idempotent)"
"${REPO_ROOT}/scripts/flutter-cmd.sh" config --enable-linux-desktop

echo "+ toolchain installed:"
for t in clang cmake ninja pkg-config Xvfb ffmpeg; do
  printf '  %s: ' "$t"
  command -v "$t" >/dev/null && echo ok || echo MISSING
done
printf '  gtk+-3.0: '
pkg-config --exists gtk+-3.0 && echo ok || echo MISSING
printf '  libsecret-1: '
pkg-config --exists libsecret-1 && echo ok || echo MISSING
