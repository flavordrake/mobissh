# In-app self-update (sideloaded Android) — spec

Status: shipped in +192 (#1214, #1215, #1216). Modelled on opsurface's self-update (`~/workspace/opsurface/lib/update/`), hardened where opsurface is weak.

## Goal

The sideloaded Android app notices a newer published build, and with one tap downloads it, proves it came from our signing key, and hands it to Android's installer. No more visiting `native.html` to update.

## Manifest contract (pinned — both slices build against this)

`native-dist/android-latest.json`, served at `https://mobissh.tailbe5094.ts.net/android-latest.json`:

```json
{
  "version": "0.1.12-rc.4+191",
  "build": 191,
  "abi": "arm64-v8a",
  "url": "https://mobissh.tailbe5094.ts.net/mobissh-native-0.1.12-rc.4+191-20260927T172906+0000.apk",
  "sha256": "<64 lowercase hex of that exact file>",
  "builtAt": "2026-09-27T17:29:06Z",
  "notes": "<top section of native-release-notes.md (#1258), else one line from the ship message; may be empty>"
}
```

- `build` is B, the global never-resetting build ordinal (`docs/VERSIONING.md`). Comparison is `build > runningBuild`, integer only; semver is never compared.
- `url` must be https and on the same host as the manifest.
- The manifest is written atomically (temp + rename) AFTER the APK it names is in place, so a reader never sees a manifest pointing at a missing or partial file.

## Requirements

### Publish side (slice 1)

- **R1** `native-release-apk.sh` computes sha256 of the stamped arm64 APK and writes `android-latest.json` per the contract, atomically, last.
- **R2** The build passes `--dart-define=MOBISSH_BUILD=<B>` so the app knows its own ordinal exactly. The `% 1000` split-per-abi decoding in `displayBuildNumber` breaks at B=1000 and must not be the source of truth for updates.
- **R3** `server/index.js` `isNativeDistArtifact` serves `android-latest.json` (no-store, `application/json`).
- **R4** `native-release-apk.sh` FAILS when the release keystore (`key.properties`) is absent, like `build-release-aab.sh` already does. Today it silently falls back to debug signing; a debug-signed build would be refused by R10 on every device and could never upgrade an installed copy.

### App side (slice 2)

- **R5** Check on app start (after bootstrap), on resume, and from Settings → Updates. No background polling from the SSH keep-alive service.
- **R6** Off-tailnet or unreachable: quiet. The banner simply doesn't appear; Settings says "Latest: unreachable — <reason>".
- **R7** A newer build shows a banner "Update <installed> → <new>" with Later / Install. Later is remembered per build for the process lifetime. Settings shows Installed / Latest and an Install button.
- **R8** Install streams the APK with progress, verifies sha256 against the manifest before writing anything to disk, then writes it to `<cacheDir>/updates/`.
- **R9** The manifest's `abi` must match the device's primary ABI; otherwise no offer is made (and Settings says why).
- **R10** **Authenticity, not just integrity.** Before hand-off, the Kotlin side reads the downloaded APK with `PackageManager.getPackageArchiveInfo(..., GET_SIGNING_CERTIFICATES)` and refuses unless (a) its package name equals the running app's and (b) its signing certificate set equals the running app's. Refusal deletes the file and shows the reason. The sha256 alone only proves the file matches a manifest served by the same host.
- **R11** Hand-off: `FileProvider` on its OWN authority (`${applicationId}.updates.fileprovider`, paths limited to `cache/updates/`) + `ACTION_VIEW` `application/vnd.android.package-archive`. If `canRequestPackageInstalls()` is false, send the user to `ACTION_MANAGE_UNKNOWN_APP_SOURCES` for this package and say so persistently (not a vanishing toast).
- **R12** Downloaded APKs in `cache/updates/` are removed on the next launch after a successful update, and on any refusal.
- **R13** `REQUEST_INSTALL_PACKAGES`, the updater FileProvider and the whole update UI are EXCLUDED from the Play AAB (Google restricts the permission, and a Play-installed copy can't be upgraded by our key anyway). Mechanism is the implementer's choice (manifest overlay for the sideload build, or `tools:node="remove"` in the AAB path) but it must be test-asserted on the built artifacts.

### Fewer taps (#1258)

- **R14** Pre-download. When a check returns a newer build and the network is unmetered (`UpdatesChannel.isUnmetered`, `ConnectivityManager.isActiveNetworkMetered`; no plugin), the foreground app downloads and verifies it exactly as R8 does, and writes it to `cache/updates/`. The banner then reads "Update ready: A → B" and Install hands off with no download wait. On a metered network nothing is fetched until the tap. A pre-download failure is quiet; the tap then downloads. The keep-alive service never does this work (D3).
- **R15** Resume after the grant. On `needsPermission` the verified file is KEPT. On the next resume, if `canInstallPackages` is now true, the app hands that file off once, with no second download and no second Install tap. Before any hand-off of a stored file (pre-downloaded or kept), its sha256 is checked again; a mismatch is deleted and downloaded again. R10 still runs in Kotlin on every hand-off.
- **R16** Post-update notice. `mobissh.update.lastRun` = `{"v":1,"build":B}`. On launch: no `MOBISSH_BUILD` → nothing; nothing stored or a corrupt value → store silently; same build → nothing; lower running build → store silently; higher running build → the snackbar "Updated to <version>", then store. "What's new" opens the notes saved at hand-off (`mobissh.update.pending` = `{"v":1,"build","version","notes"}`), so they show offline; with no saved notes for this build, the snackbar has no action. The manifest `notes` field carries the TOP section of `native-release-notes.md` (`scripts/release-notes-top.sh`); without one it stays the ship-commit subject.
- In a session: a one-time snackbar "Update B available" with Install (once per build per process, not after Later), and an "Install update B" row at the top of the session menu while an update is on offer.

Taps (the Android installer's Update and Open cannot be skipped for a sideload):

| Path | Before | After |
|---|---|---|
| From home, permission granted | 3, plus the download wait | 3, no wait on Wi-Fi |
| From a live session | 5 | 3 (snackbar Install → Update → Open), or 4 via the menu row |
| First update ever | 6, with a second download | 5 (Install → toggle → Back → Update → Open) |

## Decisions

- **D1** Integer build ordinal, not semver. B never resets and the ship script already refuses to regress it.
- **D2** Fixed manifest URL (dart-define overridable, like the feedback endpoint), not opsurface's configured feed hosts — mobissh has one distribution host.
- **D3** No background notification. opsurface rides its feed-polling service; mobissh's service exists to keep SSH alive and should not grow unrelated network work.
- **D4** Signing-cert match before hand-off (R10) is the security line. It turns "trust the host" into "trust the key".
- **D5** arm64-only offer for now, stated in the manifest (R9) rather than silently offering an APK a device can't run.

## Slices

1. Publish side — R1-R4. Scripts + server + a build define. No app UI.
2. App side — R5-R13. Depends on the contract above, not on slice 1 landing (tests use fixtures).

## Tests

- **A1** (slice 1) script test: manifest shape, sha256 matches the stamped file, url https + same host, written after the APK, atomic; keystore missing → non-zero exit before any build.
- **A2** (slice 1) server: `/android-latest.json` served no-store; other unknown JSON still 404.
- **A3** (slice 2) checker: newer/same/older build, malformed manifest, non-https url, foreign-host url, abi mismatch, unreachable.
- **A4** (slice 2) installer: sha mismatch → nothing written; match → written; refused hand-off → file deleted; progress with and without Content-Length.
- **A5** (slice 2) Kotlin/R10: an APK with a different package name is refused; an APK signed by a different key is refused; our own APK is accepted. On the emulator: sideload a debug-signed build of the app, point the checker at a manifest for a release-signed build, and assert the refusal; then the happy path reaches the system installer screen.
- **A6** (slice 2) Play build: the AAB's merged manifest has no `REQUEST_INSTALL_PACKAGES` and no updater provider.
- **A7** (#1258) headless: pre-download only when unmetered; a stored file is re-verified and handed off with no request; a mismatched one is re-fetched; `needsPermission` keeps the file and the resume with the grant hands off exactly once; the post-update decision table, corrupt values, once-only; the in-session snackbar once per build; the menu row; What's new. Infra: the notes extraction. Device (`self_update_1216_test.dart`): pre-download → one tap → the system installer with no second download; the post-update snackbar and What's new.
