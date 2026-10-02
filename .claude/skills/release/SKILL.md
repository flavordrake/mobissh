---
name: release
description: Use when the user says "release", "tag a release", "cut a release", "bump version", "ship it", "publish", or "/release". Handles version bumping, changelog generation, validation, tagging, and GitHub release creation.
---

# Release

> **Process reference:** `.claude/process.md` defines the label taxonomy, workflow states,
> and conventions that this skill must follow.

Release process for the native app. The versioning model, stage lifecycle and tag names
are defined in `docs/VERSIONING.md`; this skill is the checklist that walks it.

## Version source

The only version touchpoint is the `version:` line in `native/pubspec.yaml`
(`x.y.z[-STAGE]+B`). `scripts/ship-native.sh` auto-bumps `+B`; the STAGE edit
(`-dev` → `-rc.N` → final) is a manual edit before shipping. Nothing else carries a
version (`server/package.json` is not part of the release).

## Step 0: Owner-deferred release blockers

Before anything else, list open issues whose title contains `RELEASE BLOCKER`:

```bash
scripts/gh-ops.sh search "RELEASE BLOCKER in:title is:open"
```

Any hit must be resolved, or the owner must explicitly waive it, before tagging. Stop and WARN the owner by name of the issue; never skip it silently. Owner directive (2026-10-02, #1261 unreachable-code cleanup): "defer for next tag but warn me before I try and skip it again".

## Step 1: Decide what this release is

Read the current pubspec version and the commits since the last `native-v*` tag:

```bash
scripts/run-in-repo.sh git describe --tags --abbrev=0 --match "native-v*"
```

- **RC entry / promotion**: scope believed complete and entry gates green → set
  `x.y.z-rc.N+B`. Tag `native-vx.y.z-rc.N`, GitHub **prerelease**.
- **Final**: an rc survived acceptance unchanged → ONE promotion build as `x.y.z+B`.
  Tag `native-vx.y.z`, full GitHub release. Never re-tag rc bits: the version string is
  baked into the binary.
- After a final ships, bump to `x.y.(z+1)-dev+B` for the next cycle.

## Step 2: Changelog

Group commits since the last `native-v*` tag by prefix (`feat` Features, `fix` Bug
Fixes, `refactor`, `test`, `chore`/`build`/`docs` Maintenance, `security`; skip merge
commits). Include issue numbers; group related work rather than listing every commit.
Write it to a notes file with the Write tool.

## Step 3: Validate

Do NOT tag if any of these fail:

```bash
scripts/native-fast-gate.sh
scripts/with-fleet-emulator.sh -- scripts/native-integration-suite.sh
```

The integration suite enforces `native/integration_test/BASELINE.manifest`; a missing
emulator reports NOT VALIDATED and is not a pass. Device-labelled work still needs the
owner's hardware validation for a final.

## Step 3.5: Security audit

```bash
scripts/security-audit-native.sh {VERSION}
```

It builds the audit context (`scripts/build-security-context.sh`), runs gemini and codex
against the native attack surface, and writes reports under
`test-history/security/v{VERSION}/`. Read both reports, deduplicate, verify each
finding at its file:line, and file real ones with `scripts/gh-file-issue.sh`
(`security: ...`; critical/high/medium → `bug` + `security`, low → `chore` + `security`).
If neither tool is available, log it and proceed; note "clean audit" when nothing real
survives verification.

## Step 4: Build the release build

Edit the STAGE in `native/pubspec.yaml`, then ship with a commit message written to a
file:

```bash
scripts/ship-native.sh --message-file /tmp/mobissh/release-msg.md
```

This commits, pushes, bumps `+B`, builds and publishes the stamped arm64 APK
(`public/mobissh-native-<version>-<ts>.apk`), regenerates the install page, and
refuses to ship with doc drift (`scripts/doc-drift.sh --block`). For macOS, publish the
matching zip via the Mac pipeline in `native/MAC-BUILD.md`.

## Step 5: Tag and GitHub release

`gh-ops.sh release` creates the tag and the release in one step:

```bash
scripts/gh-ops.sh release native-v{VERSION} --title "native-v{VERSION}" --notes-file /tmp/mobissh/release-notes.md --target {SHIP_SHA} public/mobissh-native-{VERSION}-{TS}.apk
```

Attach the stamped arm64 APK, plus the stamped macOS zip when one was built for this
version.

**Gap:** `gh-ops.sh release` has no `--prerelease` flag, so an rc tag currently produces
a full release. Add the flag to `gh-ops.sh` before cutting an rc, rather than calling
raw `gh`.

## Step 6: Close fixed issues

For each issue referenced by the release commits that is still open and actually fixed:

```bash
scripts/gh-ops.sh close N --comment "Fixed in native-v{VERSION} ({COMMIT_SHA})"
scripts/gh-ops.sh labels N --rm bot --rm divergence
```

Leave partially-addressed issues open with a progress comment.

## Step 7: Post-release

```bash
scripts/container-ctl.sh ensure
```

Confirm the install page serves the new build, then bump the pubspec to the next `-dev`
version after a final.

## TRACE for Release Process

Create a TRACE for every release:

```bash
scripts/trace-init.sh "release-native-v{VERSION}"
```

Record in `strategy/initial_plan.md`: what is included, why this stage (rc vs final),
known risks. Log pivots when validation or the security audit blocks the release.
Populate `TRACE.md` with what shipped, what was held back, the audit summary and a
knowledge seed.

## Anti-Patterns

- **Don't skip validation**: "It's just a version bump" is how broken releases ship.
- **Don't re-tag rc bits as final**: ship the promotion build.
- **Don't move a stage backwards** or reset `+B`.
