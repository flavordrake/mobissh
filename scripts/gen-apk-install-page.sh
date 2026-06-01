#!/usr/bin/env bash
# scripts/gen-apk-install-page.sh — Generate the stable APK install landing page.
#
# Writes public/native.html: a stable, refreshable URL the owner can bookmark.
# The server serves it with Cache-Control: no-store, so a browser refresh always
# shows the NEWEST build — latest timestamp, git hash, and a curated "What to
# verify" list — with a big tap-to-install button pointing at the stable
# mobissh-native.apk.
#
# The "What to verify" list comes from the TOP section of native-release-notes.md
# (its `- ` bullets), NOT from git log. Raw commit subjects (merge commits,
# test(#..)/CI/refactor noise) are useless for deciding what to tap-test on the
# device — so the human curates user-facing notes in that file at ship time and
# this script renders them. Falls back to "(see native-release-notes.md)" if the
# file or its first section is missing.
#
# Why a page (not the raw .apk URL): refreshing a 78MB .apk URL just re-downloads
# the binary. A page refresh is instant and confirms which build is live before
# you spend the download.
#
# Args:
#   $1  timestamp   (the ISO-8601 build stamp, e.g. 20260601T013008+0000)
#   $2  stable_apk  (stable apk filename, e.g. mobissh-native.apk)
#   $3  stamped_apk (timestamped apk filename, for the permalink)
#
# CSP note: the server serves .html with script-src 'self' (NO inline JS) but
# style-src 'unsafe-inline' (inline CSS OK). This page is pure HTML + inline CSS.
#
# Run from repo root. Writes public/native.html. Exit 0 = written.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_DIR="${REPO_ROOT}/public"
OUT="${PUBLIC_DIR}/native.html"

TS="${1:?timestamp required}"
STABLE_APK="${2:?stable apk filename required}"
STAMPED_APK="${3:?stamped apk filename required}"

GIT_HASH="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

NOTES_FILE="${REPO_ROOT}/native-release-notes.md"

# Minimal HTML escape (& < >).
esc() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# The "What to verify" bullets come from the FIRST `## ` section of
# native-release-notes.md — its `- ` lines, in order, until the next `## `.
# This is the curated user-facing list; raw git log is not used.
notes_bullets() {
  [ -f "$NOTES_FILE" ] || return 0
  awk '
    /^## / { if (seen) exit; seen=1; next }
    seen && /^- / { sub(/^- /, ""); print }
  ' "$NOTES_FILE"
}

# Heading shown for the curated section (the first `## ` title, sans marker), so
# the page reads e.g. "Build 2026-06-01 — reliability sweep (verify on device)".
notes_heading() {
  [ -f "$NOTES_FILE" ] || { echo "What to verify"; return 0; }
  local h
  h="$(awk '/^## /{sub(/^## /,""); print; exit}' "$NOTES_FILE")"
  [ -n "$h" ] && echo "$h" || echo "What to verify"
}

NOTES_HEADING="$(notes_heading | esc)"
NOTES_HTML=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  safe="$(printf '%s' "$line" | esc)"
  NOTES_HTML="${NOTES_HTML}    <li>${safe}</li>"$'\n'
done < <(notes_bullets)
if [ -z "$NOTES_HTML" ]; then
  NOTES_HTML="    <li>(curate user-facing notes in native-release-notes.md)</li>"$'\n'
fi

# Human-readable build time from the compact stamp (best-effort; show raw too).
BUILD_LINE="${TS}"

cat > "$OUT" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>MobiSSH native — latest build</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px 18px 48px;
    font: 16px/1.5 -apple-system, system-ui, "Segoe UI", Roboto, sans-serif;
    background: #0d1117; color: #e6edf3;
    max-width: 640px; margin-inline: auto;
  }
  h1 { font-size: 1.35rem; margin: 0 0 4px; }
  .sub { color: #8b949e; font-size: 0.95rem; margin: 0 0 20px; }
  .install {
    display: block; text-align: center; text-decoration: none;
    background: #238636; color: #fff; font-weight: 700; font-size: 1.15rem;
    padding: 18px 20px; border-radius: 14px; margin: 0 0 12px;
  }
  .install:active { background: #2ea043; }
  .meta {
    background: #161b22; border: 1px solid #30363d; border-radius: 12px;
    padding: 14px 16px; margin: 18px 0;
  }
  .meta dt { color: #8b949e; font-size: 0.8rem; text-transform: uppercase; letter-spacing: .04em; }
  .meta dd { margin: 2px 0 12px; font-family: ui-monospace, "SF Mono", Menlo, monospace; word-break: break-all; }
  .meta dd:last-child { margin-bottom: 0; }
  h2 { font-size: 0.95rem; color: #8b949e; text-transform: uppercase; letter-spacing: .04em; margin: 24px 0 8px; }
  ul { margin: 0; padding-left: 20px; }
  li { margin: 4px 0; }
  .permalink { display: block; margin-top: 16px; color: #58a6ff; text-decoration: none; font-size: 0.9rem; word-break: break-all; }
  .note { color: #8b949e; font-size: 0.82rem; margin-top: 28px; border-top: 1px solid #30363d; padding-top: 14px; }
</style>
</head>
<body>
  <h1>MobiSSH native</h1>
  <p class="sub">Latest build — refresh this page any time to get the newest APK.</p>

  <a class="install" href="./${STABLE_APK}" download>⬇︎ Install latest APK</a>

  <dl class="meta">
    <dt>Build</dt><dd>${BUILD_LINE}</dd>
    <dt>Commit</dt><dd>${GIT_HASH}</dd>
  </dl>

  <h2>What to verify — ${NOTES_HEADING}</h2>
  <ul>
${NOTES_HTML}  </ul>

  <a class="permalink" href="./${STAMPED_APK}" download>Permalink to this exact build: ${STAMPED_APK}</a>

  <p class="note">This page is served with no-store caching, so a refresh always reflects the live build. The green button always points at the newest APK; the permalink pins this specific build.</p>
</body>
</html>
HTMLEOF

echo "+ wrote ${OUT} (build ${TS}, commit ${GIT_HASH})"
