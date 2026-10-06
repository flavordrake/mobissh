# MobiSSH Release

Project steps for devloop's `/release`. The versioning model, stages and tag names are
in `docs/VERSIONING.md`; where devloop's generic release steps differ, these win.

## Step 0: owner-deferred release blockers (before anything else)

```bash
scripts/gh-ops.sh search "RELEASE BLOCKER in:title is:open"
```

Every hit is resolved, or the owner explicitly waives it, before tagging. Stop and WARN
the owner, naming the issue; never skip it silently. Owner directive (2026-10-02, #1261
unreachable-code cleanup): "defer for next tag but warn me before I try and skip it again".

## Version and stage

- The only version touchpoint is the `version:` line in `native/pubspec.yaml`
  (`x.y.z[-STAGE]+B`). `scripts/ship-native.sh` bumps `+B`; the STAGE edit is manual.
  `server/package.json` is not part of the release.
- Last tag: `scripts/run-in-repo.sh git describe --tags --abbrev=0 --match "native-v*"`;
  the changelog covers the commits since it.
- RC: `x.y.z-rc.N+B`, tag `native-vx.y.z-rc.N`, GitHub prerelease.
- Final: an rc that survived acceptance unchanged gets ONE promotion build as `x.y.z+B`,
  tag `native-vx.y.z`. Never re-tag rc bits as final: the version string is baked into
  the binary. Never move a stage backwards or reset `+B`.
- After a final ships, bump to `x.y.(z+1)-dev+B`.

## Validate

The `ship` and `device` gates in `AGENTS.md`: the fast gate, then the integration suite
on a leased emulator against `native/integration_test/BASELINE.manifest`. A missing
emulator reports NOT VALIDATED, which is not a pass. Device-labelled work also needs
the owner's hardware validation for a final.

## Security audit

`scripts/security-audit-native.sh {VERSION}` builds the context
(`scripts/build-security-context.sh`), runs gemini and codex against the native attack
surface, and writes reports under `test-history/security/v{VERSION}/`. Verify each
finding at its file:line and file real ones with `scripts/gh-file-issue.sh`
(`security: ...`; critical/high/medium get `bug` + `security`, low gets `chore` +
`security`). If neither tool is available, log it and continue.

## Build, tag, publish

- Ship: `scripts/ship-native.sh --message-file F` commits, pushes, bumps `+B`, builds
  and publishes the stamped arm64 APK (`public/mobissh-native-<version>-<ts>.apk`),
  regenerates the install page, and refuses on doc drift. macOS: the matching zip via
  `native/MAC-BUILD.md`.
- Tag and release in one step, attaching the stamped APK (and the macOS zip when one was
  built for this version):
  `scripts/gh-ops.sh release native-v{VERSION} --title "native-v{VERSION}" --notes-file F --target {SHIP_SHA} public/mobissh-native-{VERSION}-{TS}.apk`
- Gap: `gh-ops.sh release` has no `--prerelease` flag, so an rc tag currently produces a
  full release. Add the flag before cutting an rc rather than calling raw `gh`.
- Close fixed issues with `Fixed in native-v{VERSION} ({SHA})`; leave partially fixed
  ones open with a progress comment.

## Post-release

`scripts/container-ctl.sh ensure`, confirm the install page serves the new build, and
bump the pubspec to the next `-dev` after a final. Every release gets a TRACE
(`release-native-v{VERSION}`).
