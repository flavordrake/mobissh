#!/usr/bin/env bash
# Launches the official Dart/Flutter MCP server (stdio) for Claude Code.
# Exposes LSP navigation (go-to-def, find-references, hover), analyze_files,
# dart_fix, dart_format, and run_tests over MCP — real symbol-accurate
# navigation for the native Flutter rewrite (#501) instead of text grep.
#
# Wired into Claude Code via:  claude mcp add dart -- scripts/mcp-dart-lsp.sh
set -euo pipefail

FLUTTER_ROOT="/home/dev/flutter"
DART_BIN="${FLUTTER_ROOT}/bin/dart"
DART_SDK="${FLUTTER_ROOT}/bin/cache/dart-sdk"

exec "${DART_BIN}" mcp-server --dart-sdk "${DART_SDK}" --flutter-sdk "${FLUTTER_ROOT}"
