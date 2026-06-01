#!/usr/bin/env bash
# Launches the TypeScript/JS LSP MCP server (@mizchi/lsmcp, tsgo preset) for
# Claude Code — real symbol-accurate navigation (go-to-def, find-references,
# rename, diagnostics) for the PWA TypeScript sources (src/) instead of grep.
#
# Pinned to Node 22: @mizchi/lsmcp requires `node:sqlite` (Node 22+); the repo's
# default Node is 20.20.1 which lacks it. tsgo preset uses @typescript/native-
# preview (the native TS compiler) — no separate language-server binary needed.
# Node 22 is installed in nvm; the repo default stays Node 20 (we pin a path).
#
# Wired into Claude Code via:  claude mcp add ts -- scripts/mcp-ts-lsp.sh
set -euo pipefail

NODE_BIN="/home/dev/.nvm/versions/node/v22.22.3/bin"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export PATH="${NODE_BIN}:${PATH}"
cd "${REPO_ROOT}"

exec "${NODE_BIN}/npx" -y @mizchi/lsmcp -p tsgo
