#!/usr/bin/env bash
# scripts/render-macos-slot.sh — render the macOS download block for native.html.
#
# The macOS artifact's source of truth is native-dist/macos-latest.json (written
# by scripts/publish-native-macos.sh). This script turns that JSON into the HTML
# block that appears on the install page. It prints NOTHING (exit 0) when no
# macOS build has been published yet, so both the APK page generator
# (gen-apk-install-page.sh) and the macOS publisher can include the slot
# unconditionally — the page simply has no macOS section until the first mac ship.
#
# Shared by gen-apk-install-page.sh (APK ship regenerates the whole page, incl.
# this slot from the JSON) and publish-native-macos.sh (mac ship refreshes only
# the slot in place). One renderer = the two paths can never disagree.
#
# Usage: scripts/render-macos-slot.sh [path/to/macos-latest.json]
#   Default search: native-dist/macos-latest.json, then public/macos-latest.json.
set -euo pipefail
cd "$(dirname "$0")/.."

JSON="${1:-}"
if [ -z "$JSON" ]; then
  if [ -f native-dist/macos-latest.json ]; then
    JSON="native-dist/macos-latest.json"
  elif [ -f public/macos-latest.json ]; then
    JSON="public/macos-latest.json"
  else
    exit 0
  fi
fi
[ -f "$JSON" ] || exit 0

node -e '
  const fs = require("fs");
  let m;
  try { m = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
  catch { process.exit(0); }              // unreadable/corrupt → no slot, not a crash
  if (!m || !m.stable) process.exit(0);
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g,
    (c) => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", "\"":"&quot;" }[c]));
  // Fetch the stable alias (always newest); save under the stamped name so each
  // download is uniquely identifiable on disk — mirrors the APK block.
  process.stdout.write(`  <a class="install macos" href="./${esc(m.stable)}" download="${esc(m.stamped || m.stable)}">⬇︎ Download macOS app (.zip)</a>
  <dl class="meta">
    <dt>macOS version</dt><dd>${esc(m.version || "unknown")}</dd>
    <dt>Built</dt><dd>${esc(m.human || m.stamp || "")}</dd>
    <dt>Commit</dt><dd>${esc(m.commit || "")}</dd>
    <dt>SHA-256</dt><dd>${esc(m.sha256 || "")}</dd>
  </dl>
  <p class="note">Unzip and drag <strong>MobiSSH.app</strong> to Applications. Unsigned build — on first launch right-click the app → <strong>Open</strong> to get past Gatekeeper.</p>
`);
' "$JSON"
