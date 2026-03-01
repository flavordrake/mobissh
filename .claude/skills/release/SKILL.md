---
name: release
description: Use when the user says "release", "tag a release", "cut a release", "bump version", "ship it", "publish", or "/release". Handles version bumping, changelog generation, validation, tagging, and GitHub release creation.
---

# Release

> **Process reference:** `.claude/process.md` defines the label taxonomy, workflow states,
> and conventions that this skill must follow.

Automated release process for MobiSSH. Handles version bumping across all touchpoints, changelog generation from git history, full validation, and tagging.

## Version Touchpoints

Every release must update ALL of these in sync:

| File | Field | Example |
|------|-------|---------|
| `server/package.json` | `"version"` | `"0.3.0"` |
| `public/sw.js` | `CACHE_NAME` | `'mobissh-v17'` |

The server reads version from `server/package.json` at startup and injects it as `<meta name="app-version" content="{version}:{git-hash}">`. The SW cache name must be bumped to invalidate old cached shells on client devices.

Root `package.json` has no version field (private workspace). Don't add one.

## Step 1: Determine Next Version

```bash
# Latest tag and commits since
git describe --tags --abbrev=0
git log $(git describe --tags --abbrev=0)..HEAD --oneline | wc -l
git log $(git describe --tags --abbrev=0)..HEAD --oneline
```

Version bump rules (semver):
- **Patch** (0.2.x → 0.2.1): Only bug fixes, no new features, no breaking changes
- **Minor** (0.2.0 → 0.3.0): New features, new test infrastructure, refactors, new skills. No breaking API/protocol changes.
- **Major** (0.x → 1.0): Breaking changes to WS protocol, vault format, or deployment model

For MobiSSH's current maturity (pre-1.0), minor bumps are the norm. 85 commits with features = minor.

## Step 2: Generate Changelog

Group commits since last tag by category. Parse commit prefixes:

| Prefix | Category |
|--------|----------|
| `feat:`, `feat(` | Features |
| `fix:`, `fix(` | Bug Fixes |
| `refactor:` | Refactoring |
| `test:` | Testing |
| `chore:`, `build:`, `docs:` | Maintenance |
| `security:` | Security |
| `Merge pull request` | Skip (noise) |

Format as a concise changelog section. Include issue numbers where present. Don't list every commit — group related work (e.g., "TypeScript migration Phases 0-5" not 10 separate phase commits).

## Step 3: Validate

Run the full CI gate before tagging. ALL must pass:

```bash
npx tsc --noEmit                    # TypeScript typecheck
npx eslint src/ public/ server/ tests/  # ESLint
semgrep --config .semgrep/rules.yml --config p/typescript --config p/javascript src/ --no-git-ignore --error --severity WARNING  # Semgrep
npx vitest run                      # Unit tests
npx playwright test                 # Headless E2E
```

If an emulator is available (`adb devices | grep emulator`), also run:
```bash
bash scripts/run-emulator-tests.sh
```

Do NOT tag if any validation fails. Fix first, commit, then re-run.

## Step 4: Bump Versions

Update all touchpoints:

1. **`server/package.json`**: Update `"version"` field
2. **`public/sw.js`**: Increment `CACHE_NAME` suffix (e.g., `mobissh-v16` → `mobissh-v17`)

The SW cache suffix is a monotonically increasing integer, not tied to semver. Just increment by 1 from whatever the current value is.

## Step 5: Commit and Tag

```bash
git add server/package.json public/sw.js
git commit -m "release: v{VERSION}"
git tag -a "v{VERSION}" -m "{CHANGELOG_SUMMARY}"
```

The tag message should contain the full changelog section (not just the version number). This is the primary record of what changed.

## Step 6: Close Fixed Issues

Scan the changelog commits for issue references (`#N`, `fix(#N)`, `feat(#N)`). For each referenced issue that is still open:

1. Check the issue is actually fixed by this release (read the issue, verify the fix commit)
2. Close with a comment linking the release, and clean up delegation labels per `.claude/process.md`:

```bash
gh issue close N --comment "Fixed in v{VERSION} ({COMMIT_SHA})"
# Remove delegation labels if present (issue is resolved, no longer in delegation lifecycle)
gh issue edit N --remove-label bot --remove-label divergence 2>/dev/null || true
```

3. Add the release version label:

```bash
gh issue edit N --add-label "v{VERSION}"
```

If there's no label for this version yet, create one:

```bash
gh label create "v{VERSION}" --description "Released in v{VERSION}" --color "0E8A16"
```

Don't close issues that are only partially addressed. If a commit references an issue but only fixes part of it, leave the issue open and add a comment noting partial progress.

## Step 7: GitHub Release

Create a GitHub release with the changelog:

```bash
gh release create "v{VERSION}" --title "v{VERSION}" --notes "{CHANGELOG}"
```

## Step 8: Push

Ask the user before pushing. Show what will be pushed:

```bash
git log origin/main..HEAD --oneline
git tag -l --sort=-version:refname | head -3
```

Then push:
```bash
git push origin main --follow-tags
```

## Step 9: Post-Release Verification

After push, verify the production server if accessible:

```bash
bash scripts/server-ctl.sh ensure
bash scripts/server-ctl.sh status
```

Check that the version meta tag matches the new release.

## SW Cache Name History

Track cache name bumps here for reference. The number is not semver — it's a monotonic counter for cache invalidation.

| Version | SW Cache | Notes |
|---------|----------|-------|
| v0.2.0 | mobissh-v16 | Last known state before this skill |

## Anti-Patterns

- **Don't skip validation**: "It's just a version bump" is how broken releases ship.
- **Don't forget sw.js**: Stale cache name = users stuck on old code until they manually clear.
- **Don't amend the release commit**: If something needs fixing, make a new commit and a new patch release.
- **Don't tag without committing version bumps first**: The tag should point at the commit that contains the new version numbers.
