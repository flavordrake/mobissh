#!/usr/bin/env bash
# scripts/dispatch-mac-build.sh — kick off a macOS build on the runner Mac (#1026).
#
# fd-dev can't build macOS (no Xcode). This sends the build directive to the Mac
# over the agent-hub bus; the Mac runs scripts/mac/build-native-macos.sh, stages
# the zip, and replies with the `host:path` + digest. fd-dev then pulls + publishes
# with scripts/publish-native-macos.sh — which lands it on native.html.
#
# This is the local "kick them off" entry point. It does not wait; the Mac's reply
# arrives on the bus (watch `hub inbox`), then run the publish command it prints.
#
# Usage: scripts/dispatch-mac-build.sh [mac-agent-name]   (default matts-macbook-air-it)
set -euo pipefail

HUB="$(command -v hub || echo "$HOME/.local/bin/hub")"
[ -x "$HUB" ] || { echo "! hub CLI not found (expected on PATH or ~/.local/bin/hub)" >&2; exit 2; }

MAC="${1:-matts-macbook-air-it}"

BODY="Pull latest flavordrake/mobissh main, then run scripts/mac/build-native-macos.sh (needs Xcode + Flutter, see scripts/mac/README.md). It builds+zips the macOS .app and pushes it to my ~/mobissh-native-dist/, then prints a one-line reply. Relay that line back so I publish to native.html: hub send fd-dev-IT \"done: macOS build staged on fd-dev\" \"from ~/mobissh-native-dist/<zip> version <v> stamp <s> commit <c> sha256 <h>\"."

"$HUB" send "$MAC" "DIRECTIVE: build+stage macOS app for native.html" "$BODY"
echo "+ dispatched macOS build to ${MAC}. Watch: hub inbox"
echo "+ on reply, publish: scripts/publish-native-macos.sh --from <host:zip> --version <v> --stamp <s> --commit <c> --sha256 <h>"
