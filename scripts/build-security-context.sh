#!/usr/bin/env bash
# scripts/build-security-context.sh — assemble the audit context an AI security
# reviewer needs to reason about MobiSSH's REAL attack surface.
#
# Without this the tools hallucinate a generic web app: they flag "no auth on the
# WebSocket bridge" (Tailscale is the auth boundary) and miss the things that
# actually matter here (vault bypass, key material handling, SFTP path handling).
#
# Usage: scripts/build-security-context.sh <out-file>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: build-security-context.sh <out-file>}"
mkdir -p "$(dirname "$OUT")"

{
  echo "# MobiSSH — Security Audit Context"
  echo
  cat "${REPO_ROOT}/CLAUDE.md"
  echo
  echo "---"
  echo
  cat "${REPO_ROOT}/.claude/rules/security.md"
  echo
  echo "---"
  echo
  cat "${REPO_ROOT}/.claude/rules/server.md"
} > "$OUT"

echo "> context written: $OUT ($(wc -l < "$OUT") lines)"
