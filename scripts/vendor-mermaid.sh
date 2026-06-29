#!/usr/bin/env bash
# scripts/vendor-mermaid.sh — vendor the mermaid.js UMD bundle as an OFFLINE asset (#942/#944)
#
# The native markdown viewer renders ```mermaid fenced blocks as diagrams by
# loading this bundle into an offline WebView (no CDN/network at runtime — see
# native/lib/ui/mermaid_diagram_view.dart). This script fetches the bundle ONCE
# at dev time and commits it under native/assets/mermaid/. It is NOT run at
# build or runtime.
#
# mermaid 10.9.3 dist/mermaid.min.js is a UMD build that exposes window.mermaid,
# usable from a plain <script> tag in loadHtmlString (no ESM module server).

set -euo pipefail

MERMAID_VERSION="${MERMAID_VERSION:-10.9.3}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_DIR="${REPO_ROOT}/native/assets/mermaid"
ASSET_FILE="${ASSET_DIR}/mermaid.min.js"
SRC_URL="https://cdn.jsdelivr.net/npm/mermaid@${MERMAID_VERSION}/dist/mermaid.min.js"

mkdir -p "$ASSET_DIR"

echo "Vendoring mermaid@${MERMAID_VERSION} from ${SRC_URL}"
curl -fSL "$SRC_URL" -o "$ASSET_FILE"

if ! grep -q "mermaid=" "$ASSET_FILE"; then
  echo "ERROR: downloaded bundle does not look like the mermaid UMD build" >&2
  exit 1
fi

echo "Wrote $ASSET_FILE ($(wc -c < "$ASSET_FILE") bytes)"
