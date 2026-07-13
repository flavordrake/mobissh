# macOS build & publish (#1026)

Where and how a macOS build of the app runs, and how it reaches the `native.html`
install page — the mac analog of the Android `scripts/native-release-apk.sh` path.

## Where it runs

The macOS `.app` is built on **matts-macbook-air** (bus identity
`matts-macbook-air-it`) — the fleet's only host with Xcode. fd-dev cannot build
macOS. The build itself is `flutter build macos` (see `DESKTOP.md`); the `macos/`
runner scaffolding + entitlements are committed. iOS device builds are a separate,
signing-gated effort (paid Apple account + provisioning) and are **out of scope**
here — this pipeline ships the **macOS desktop app** only.

## The split: build on the Mac, publish on fd-dev

Publishing means landing the artifact in fd-dev's persistent bind-mounted
`native-dist/` (served by `mobissh-prod` over Tailscale) and updating
`native.html`. That is fd-dev-owned. So the pipeline crosses hosts:

| Step | Host | Script |
|------|------|--------|
| 1. Dispatch the build | fd-dev | `scripts/dispatch-mac-build.sh` → bus DIRECTIVE to `matts-macbook-air-it` |
| 2. Build + zip + stage | Mac | `scripts/mac/build-native-macos.sh` → `~/mobissh-native-dist/mobissh-native-macos-<ver>-<stamp>.zip` |
| 3. Relay result | Mac | `hub send fd-dev-IT "done: …" "from <host>:<zip> version … stamp … commit … sha256 …"` |
| 4. Pull + publish | fd-dev | `scripts/publish-native-macos.sh --from <host:zip> --version … --stamp … --commit … --sha256 …` |

Step 4 rsync-pulls the zip over the tailnet, verifies the sha256, lands it in
`native-dist/` under a stable alias (`mobissh-native-macos.zip`) + a versioned
permalink, writes `macos-latest.json`, and refreshes the macOS slot on
`native.html`.

## Kick one off locally

```sh
scripts/dispatch-mac-build.sh          # sends the build directive to the Mac
hub inbox                              # watch for the Mac's `done:` reply
# then paste the publish command the reply carries:
scripts/publish-native-macos.sh --from matts-macbook-air:/Users/…/…zip \
  --version 0.1.10+NN --stamp 20260713T… --commit <hash> --sha256 <hex>
```

## How it lands on native.html

`macos-latest.json` (in `native-dist/`) is the **source of truth** for the macOS
download. Two paths render it, so neither wipes the other:

- `scripts/gen-apk-install-page.sh` (every APK ship) regenerates the whole page
  and renders the macOS slot from the JSON via `scripts/render-macos-slot.sh` —
  so an APK ship never drops a published macOS download.
- `scripts/publish-native-macos.sh` (every mac ship) refreshes just the slot in
  place, between the `<!--MACOS-START-->` / `<!--MACOS-END-->` markers — no APK
  rebuild needed.

The server serves `mobissh-native-macos*.zip` + `macos-latest.json` from
`native-dist/` (`isNativeDistArtifact` in `server/index.js`). The bundle is
**unsigned**: the page tells the user to right-click → Open past Gatekeeper.

## First-run status

`scripts/mac/*` (including the build script) have never executed on a real Mac —
they are `bash -n`-validated only. The Mac must first satisfy the prereqs in
`scripts/mac/README.md` (full Xcode, Flutter ≥ 3.44, `flutter doctor` clean).
Expect first-contact fixes on the first real build.
