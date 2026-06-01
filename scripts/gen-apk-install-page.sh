#!/usr/bin/env bash
# scripts/gen-apk-install-page.sh — Generate the stable APK install landing page.
#
# Writes public/native.html: a stable, refreshable URL the owner can bookmark.
# The server serves it with Cache-Control: no-store, so a browser refresh always
# shows the NEWEST build — latest timestamp, git hash, and recent native commits
# — with a big tap-to-install button pointing at the stable mobissh-native.apk.
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

# Recent native-facing commits as the "what's new" list. Plain text, HTML-escaped
# below via a here-free sed; we keep it simple and safe (subjects only, no bodies).
recent_commits() {
  git -C "$REPO_ROOT" log -8 --pretty=format:'%s' || true
}

# Minimal HTML escape for commit subjects (& < >).
esc() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

COMMITS_HTML=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  safe="$(printf '%s' "$line" | esc)"
  COMMITS_HTML="${COMMITS_HTML}    <li>${safe}</li>"$'\n'
done < <(recent_commits)

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

  <h2>What's new</h2>
  <ul>
${COMMITS_HTML}  </ul>

  <a class="permalink" href="./${STAMPED_APK}" download>Permalink to this exact build: ${STAMPED_APK}</a>

  <p class="note">This page is served with no-store caching, so a refresh always reflects the live build. The green button always points at the newest APK; the permalink pins this specific build.</p>
</body>
</html>
HTMLEOF

echo "+ wrote ${OUT} (build ${TS}, commit ${GIT_HASH})"
