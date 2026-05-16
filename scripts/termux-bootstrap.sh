#!/usr/bin/env bash
# termux-bootstrap.sh — Set up MobiSSH bridge on a fresh Termux install.
#
# What this script does:
#   1. Verifies it is running inside Termux (E2)
#   2. Installs nodejs and git via pkg if not already present (E3)
#   3. Clones or updates the MobiSSH repo to ~/mobissh (E4)
#   4. Runs npm install --omit=dev inside server/ (E5)
#   5. Prints the exact next-step command to start the bridge (E6)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/flavordrake/mobissh/main/scripts/termux-bootstrap.sh | bash
#
# Requirements: Termux on Android (https://termux.dev)

set -euo pipefail

REPO_URL="https://github.com/flavordrake/mobissh.git"
REPO_BRANCH="main"
INSTALL_DIR="${HOME}/mobissh"

# ── E2: Termux detection ──────────────────────────────────────────────────────
# Termux sets $PREFIX to /data/data/com.termux/files/usr (or similar).
# We also check for the `pkg` binary as a belt-and-suspenders guard.

is_termux() {
  # PREFIX containing com.termux is the canonical indicator
  if [ -n "${PREFIX:-}" ] && echo "${PREFIX}" | grep -q "com.termux"; then
    return 0
  fi
  # Secondary check: TERMUX_VERSION env var set by the Termux app itself
  if [ -n "${TERMUX_VERSION:-}" ]; then
    return 0
  fi
  return 1
}

if ! is_termux; then
  echo "error: this script must be run inside Termux" >&2
  exit 1
fi

# ── E3: Install required packages idempotently ────────────────────────────────

need_pkg() {
  command -v "$1" >/dev/null 2>&1
  return $?
}

PKGS_TO_INSTALL=""
if ! need_pkg node; then
  PKGS_TO_INSTALL="${PKGS_TO_INSTALL} nodejs"
fi
if ! need_pkg git; then
  PKGS_TO_INSTALL="${PKGS_TO_INSTALL} git"
fi

if [ -n "${PKGS_TO_INSTALL}" ]; then
  echo "Installing:${PKGS_TO_INSTALL}"
  # shellcheck disable=SC2086
  pkg install -y ${PKGS_TO_INSTALL}
fi

# ── E4: Clone or update the repo ──────────────────────────────────────────────

if [ -d "${INSTALL_DIR}/.git" ]; then
  echo "Updating existing repo at ${INSTALL_DIR}"
  git -C "${INSTALL_DIR}" fetch origin
  git -C "${INSTALL_DIR}" checkout "${REPO_BRANCH}"
  git -C "${INSTALL_DIR}" reset --hard "origin/${REPO_BRANCH}"
else
  echo "Cloning MobiSSH to ${INSTALL_DIR}"
  git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
fi

# ── E5: Install server dependencies ───────────────────────────────────────────

SERVER_DIR="${INSTALL_DIR}/server"

if [ -f "${SERVER_DIR}/package-lock.json" ]; then
  npm ci --omit=dev --prefix "${SERVER_DIR}"
else
  npm install --omit=dev --prefix "${SERVER_DIR}"
fi

# Verify ssh2 is importable
node -e "require('ssh2')" --prefix "${SERVER_DIR}" 2>/dev/null || \
  node -e "require('${SERVER_DIR}/node_modules/ssh2')"

echo ""
echo "MobiSSH bridge is ready. Run this command to start it with local port-forwarding enabled:"
echo ""
# ── E6: Print the next-step command ───────────────────────────────────────────
echo "MOBISSH_LOCAL_FORWARDS=1 node ${INSTALL_DIR}/server/index.js"
echo ""
echo "Then open http://127.0.0.1:8081/ in Termux's browser (or any browser on your device)."
