#!/usr/bin/env bash
# scripts/publish-native-macos.sh — publish a Mac-built macOS app to native.html.
#
# The macOS bundle is BUILT on the Mac (scripts/mac/build-native-macos.sh — the
# only host with Xcode). This runs on fd-dev, which owns publishing: it lands the
# zip in the persistent bind-mounted native-dist/ (served by mobissh-prod over
# Tailscale), records macos-latest.json (source of truth for the install page's
# macOS slot), and refreshes that slot in the live native.html — no APK rebuild.
#
# The build+publish split mirrors the Android path (build → native-dist/ → page),
# except the build hop crosses hosts, so the zip is pulled from the Mac here.
#
# Usage:
#   scripts/publish-native-macos.sh \
#     --from <local.zip | host:/abs/remote.zip>   # rsync-pulled if host:path
#     --version <X.Y.Z+N>                          # from native/pubspec.yaml
#     --stamp <YYYYMMDDThhmmss+zzzz>               # build stamp (compact ISO)
#     --commit <shorthash>                         # commit built from
#     [--sha256 <hex>]                             # verify the transfer if given
#
# Exit 0 = published (prints the download URL). 2 = arg/transfer/verify error.
set -euo pipefail
cd "$(dirname "$0")/.."

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/publish-native-macos.log"
exec > >(tee -a "$LOGFILE") 2>&1

NATIVE_DIST="${NATIVE_DIST_HOST:-/home/dev/workspace/mobissh/native-dist}"
PUBLIC_DIR="${PUBLIC_DIR:-$(pwd)/public}"

FROM="" VERSION="" STAMP="" COMMIT="" WANT_SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from)    FROM="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --stamp)   STAMP="${2:-}"; shift 2 ;;
    --commit)  COMMIT="${2:-}"; shift 2 ;;
    --sha256)  WANT_SHA="${2:-}"; shift 2 ;;
    *) echo "! publish-native-macos: unknown arg: $1" >&2; exit 2 ;;
  esac
done
for req in FROM VERSION STAMP COMMIT; do
  if [ -z "${!req}" ]; then echo "! publish-native-macos: --${req,,} is required" >&2; exit 2; fi
done

# 1. Resolve the source zip. A `host:/path` source is pulled over the tailnet with
#    rsync-over-ssh (fd-dev -> Mac); a plain path is used in place (local test).
STAGE="${MOBISSH_TMPDIR}/mobissh-native-macos.stage.zip"
rm -f "$STAGE"
case "$FROM" in
  *:*)
    if [[ ! -e "$FROM" ]]; then
      echo "> pulling ${FROM} over tailnet (rsync)"
      rsync -e ssh -az --timeout=120 "$FROM" "$STAGE"
    else
      cp "$FROM" "$STAGE"        # a local path that happens to contain ':'
    fi
    ;;
  *)
    if [ ! -f "$FROM" ]; then echo "! publish-native-macos: no such zip: $FROM" >&2; exit 2; fi
    cp "$FROM" "$STAGE" ;;
esac

# 2. Verify the transfer if the builder gave us a digest (catch truncation).
GOT_SHA="$(sha256sum "$STAGE" | cut -d' ' -f1)"
if [ -n "$WANT_SHA" ] && [ "$GOT_SHA" != "$WANT_SHA" ]; then
  echo "! publish-native-macos: sha256 mismatch — got ${GOT_SHA}, expected ${WANT_SHA}" >&2
  exit 2
fi

# 3. Publish under a stable alias (newest) + a versioned+stamped permalink, into
#    both native-dist/ (live-served, survives container recreate) and public/.
STABLE="mobissh-native-macos.zip"
STAMPED="mobissh-native-macos-${VERSION}-${STAMP}.zip"
mkdir -p "$NATIVE_DIST"
for d in "$NATIVE_DIST" "$PUBLIC_DIR"; do
  cp "$STAGE" "${d}/${STABLE}"
  cp "$STAGE" "${d}/${STAMPED}"
done

# 4. Human-readable build time from the compact stamp (best-effort; falls back to
#    the raw stamp if it can't be parsed).
iso="${STAMP:0:4}-${STAMP:4:2}-${STAMP:6:2}T${STAMP:9:2}:${STAMP:11:2}:${STAMP:13:2}${STAMP:15}"
if HUMAN="$(date -u -d "$iso" '+%Y-%m-%d %H:%M UTC' 2>/dev/null)"; then :; else HUMAN="$STAMP"; fi

# 5. macos-latest.json — the source of truth the page generator + slot renderer
#    read. Written to both dirs so either serving root has it.
MANIFEST="${MOBISSH_TMPDIR}/macos-latest.json"
OUT="$MANIFEST" node -e '
  const fs = require("fs");
  const [version, stamp, human, commit, sha, stable, stamped] = process.argv.slice(1);
  fs.writeFileSync(process.env.OUT, JSON.stringify(
    { version, stamp, human, commit, sha256: sha, stable, stamped }, null, 2) + "\n");
' "$VERSION" "$STAMP" "$HUMAN" "$COMMIT" "$GOT_SHA" "$STABLE" "$STAMPED"
cp "$MANIFEST" "${NATIVE_DIST}/macos-latest.json"
cp "$MANIFEST" "${PUBLIC_DIR}/macos-latest.json"

# 6. Refresh the macOS slot in the live install page(s) in place — no APK rebuild.
#    If native.html has no macOS markers yet (never regenerated since #1026), warn;
#    the next APK ship (gen-apk-install-page.sh) adds them and renders the slot.
SLOT="$("$(pwd)/scripts/render-macos-slot.sh" "$MANIFEST" || true)"
refresh_page() {
  local page="$1"
  [ -f "$page" ] || return 0
  SLOT_HTML="$SLOT" node -e '
    const fs = require("fs");
    const p = process.argv[1];
    let s = fs.readFileSync(p, "utf8");
    const START = "<!--MACOS-START-->", END = "<!--MACOS-END-->";
    const block = START + "\n  <section class=\"macos-dl\">\n" +
      (process.env.SLOT_HTML || "") + "\n  </section>\n  " + END;
    if (s.includes(START) && s.includes(END)) {
      s = s.replace(new RegExp(START + "[\\s\\S]*?" + END), block);
      fs.writeFileSync(p, s);
      process.exit(0);
    }
    process.exit(3);                    // no markers — signal the caller to warn
  ' "$page" || echo "! ${page}: no MACOS markers — run an APK ship (gen-apk-install-page.sh) to add them" >&2
}
refresh_page "${NATIVE_DIST}/native.html"
refresh_page "${PUBLIC_DIR}/native.html"

echo "+ PUBLISHED macOS ${VERSION} (${STAMP})"
echo "+ stable  : https://mobissh.tailbe5094.ts.net/${STABLE}"
echo "+ permalink: https://mobissh.tailbe5094.ts.net/${STAMPED}"
echo "+ install page: https://mobissh.tailbe5094.ts.net/native.html"
