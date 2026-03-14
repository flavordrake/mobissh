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

The server reads version from `server/package.json` at startup and injects it as `<meta name="app-version" content="{version}:{git-hash}">`.

`public/sw.js` `CACHE_NAME` is automatically derived from a content hash of `public/` files by `container-ctl.sh` at build time. No manual bump needed — it changes only when actual file content changes.

Root `package.json` has no version field (private workspace). Don't add one.

## Step 1: Determine Next Version

```bash
# Latest tag and commits since
git describe --tags --abbrev=0
git log $(git describe --tags --abbrev=0)..HEAD --oneline | wc -l
git log $(git describe --tags --abbrev=0)..HEAD --oneline
```

Version bump rules (semver):
- **Patch** (0.2.x -> 0.2.1): Only bug fixes, no new features, no breaking changes
- **Minor** (0.2.0 -> 0.3.0): New features, new test infrastructure, refactors, new skills. No breaking API/protocol changes.
- **Major** (0.x -> 1.0): Breaking changes to WS protocol, vault format, or deployment model

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

Format as a concise changelog section. Include issue numbers where present. Don't list every commit -- group related work (e.g., "TypeScript migration Phases 0-5" not 10 separate phase commits).

## Step 3: Validate

Run the full CI gate before tagging. ALL must pass:

```bash
scripts/test-fast-gate.sh           # TypeScript + ESLint + Vitest
scripts/test-headless.sh            # Headless Playwright E2E
```

If an emulator is available (`adb devices | grep emulator`), also run:
```bash
scripts/run-emulator-tests.sh
scripts/run-appium-tests.sh         # Appium gesture baseline
```

Do NOT tag if any validation fails. Fix first, commit, then re-run.

## Step 3.5: Security Audit (Gemini + Codex)

Static security analysis using the AI tools installed on this container. Review
`.claude/rules/security.md` for the project's security posture, then run each tool
with a security-focused prompt against the codebase.

### Setup

```bash
VERSION="{VERSION}"  # from Step 1
SECURITY_DIR="test-history/security/v${VERSION}"
mkdir -p "$SECURITY_DIR"
```

### Build the context prompt

Before running the tools, assemble a context file with the project documentation so
the auditors understand what MobiSSH is, its architecture, trust boundaries, and
security policy. Without this they hallucinate about the attack surface.

```bash
CONTEXT_FILE="$SECURITY_DIR/audit-context.md"
cat > "$CONTEXT_FILE" << 'CONTEXT_EOF'
# MobiSSH — Security Audit Context
CONTEXT_EOF

# Append project docs that define intent, architecture, and security posture
cat CLAUDE.md >> "$CONTEXT_FILE"
echo -e "\n---\n" >> "$CONTEXT_FILE"
cat .claude/rules/security.md >> "$CONTEXT_FILE"
echo -e "\n---\n" >> "$CONTEXT_FILE"
cat .claude/rules/server.md >> "$CONTEXT_FILE"
```

### Prompts

The prompts include the assembled context so the tools understand:
- MobiSSH is a mobile-first SSH PWA over Tailscale (network-layer auth, no public internet)
- Single Node.js process: HTTP static + WebSocket SSH bridge on port 8081
- AES-GCM vault with PasswordCredential (Chrome/Android biometric)
- Cache-Control: no-store on all responses, SW network-first
- Container deployment with baked git hash, Tailscale serve for HTTPS

The audit concerns from `security.md`: plaintext credential storage, vault bypass
paths, cache policy violations, secret leakage, XSS/injection in the WebSocket
bridge, and SSRF via the SSH proxy.

**Gemini** (headless, non-interactive):

```bash
gemini -p "$(cat "$CONTEXT_FILE")

---

You are a security auditor. The project documentation above describes what MobiSSH
is, how it's deployed, and its security policy. Use this to understand the real
attack surface — don't guess.

Key trust boundaries:
- Tailscale mesh provides network-layer auth (no public internet exposure)
- WebSocket bridge proxies SSH — the bridge itself has no auth beyond Tailscale
- AES-GCM vault stores credentials client-side with biometric unlock
- Service worker caches for offline only (network-first, no-store headers)

Audit for security issues, ranked by severity (critical/high/medium/low):
1. Credential handling: plaintext storage, vault bypass, key material in localStorage/logs
2. WebSocket bridge: command injection, SSRF via SSH host/port params, auth bypass
3. Service worker: cache poisoning, stale credential serving, scope escalation
4. XSS vectors: user input rendered without sanitization (terminal output, profile names)
5. Dependencies: known CVEs in server/package.json deps
6. Docker/deployment: container escape paths, exposed ports, secret leakage in build args

For each finding: severity, file:line, description, recommended fix.
Skip theoretical issues that don't apply given the Tailscale-only deployment.
Output as markdown." > "$SECURITY_DIR/gemini-audit.md" 2>&1
```

**Codex** (non-interactive exec mode):

```bash
codex exec "$(cat "$CONTEXT_FILE")

---

You are a security auditor. The project documentation above describes MobiSSH's
architecture, deployment model, and security policy. Read it carefully before auditing.

Key facts:
- Deployed on Tailscale mesh only — not public internet
- Single Node.js process: static files + WebSocket SSH bridge on port 8081
- AES-GCM vault with PasswordCredential for credential storage
- Cache-Control: no-store on all static responses, SW is network-first
- Docker container with baked git hash, Tailscale serve for HTTPS termination

Review this codebase for:
1. Plaintext credential storage or vault bypass paths (policy: block feature if vault unavailable)
2. WebSocket/SSH proxy injection or SSRF (user-supplied host/port forwarded to ssh2)
3. Cache-Control violations (must be no-store on ALL static responses)
4. XSS in terminal output, profile names, or user input handling
5. Secret leakage in logs, error messages, console output, or git history
6. Dependency vulnerabilities in server/package.json

Report findings as: severity | file:line | description | fix.
Only report findings that are real given the architecture. No theoretical noise.
Output as markdown." > "$SECURITY_DIR/codex-audit.md" 2>&1
```

### Assess and File Issues

Read both reports:

```
$SECURITY_DIR/gemini-audit.md
$SECURITY_DIR/codex-audit.md
```

For each finding:

1. **Deduplicate** — if both tools flag the same issue, merge into one
2. **Verify** — read the referenced file:line to confirm the finding is real (not hallucinated)
3. **Classify** — map to issue labels per `.claude/process.md`:
   - Critical/High → `bug` + `security`, file immediately
   - Medium → `bug` + `security`, file with context
   - Low/Informational → `chore` + `security`, batch into one issue or skip if noise
4. **File** — use `scripts/gh-file-issue.sh` for each real finding. Title format:
   `security: {brief description}`. Body should include the tool's analysis, the
   verified file:line, and the recommended fix.

Stage the audit results:

```bash
git add "$SECURITY_DIR/"
```

These get included in the release commit (Step 5) as permanent evidence of the
security review for this version.

### Skip conditions

- If neither `gemini` nor `codex` is available, log a warning and skip. Do NOT
  block the release for missing tools.
- If a tool hangs (>5 min), kill it, log the timeout, and proceed with the other tool's results.
- If no findings are real after verification, note "clean audit" in the release notes.

## Step 4: Bump Versions

Update all touchpoints:

1. **`server/package.json`**: Update `"version"` field

`public/sw.js` `CACHE_NAME` is auto-derived by `container-ctl.sh` at build time (content hash of `public/` files). No manual bump needed.

## Step 5: Commit and Tag

```bash
git add server/package.json test-history/
git commit -m "release: v{VERSION}"
git tag -a "v{VERSION}" -m "{CHANGELOG_SUMMARY}"
```

The tag message should contain the full changelog section (not just the version number). This is the primary record of what changed.

## Step 5.5: Archive Test History

Move timestamped test-history runs into a versioned directory for the release. This creates a permanent record of test evidence (video recordings with gesture debug overlays, screenshots, HTML reports) tied to each version.

```bash
# Create versioned archive directory
mkdir -p test-history/appium/v{VERSION}

# Move all timestamped runs since last release into versioned dir
# (each run-appium-tests.sh invocation creates test-history/appium/YYYYMMDD-HHMMSS/)
for dir in test-history/appium/20*; do
  [ -d "$dir" ] && mv "$dir" "test-history/appium/v{VERSION}/$(basename "$dir")"
done

# Stage and include in the release commit
git add test-history/
```

Video files (.webm, .mp4) are stored in Git LFS (`.gitattributes` has `filter=lfs diff=lfs merge=lfs -text`). Screenshot PNGs use `binary -diff`. Videos are the primary evidence that gestures work correctly at each release point. If new video files were committed before the LFS rules existed, run `git lfs migrate import --include="test-history/**/*.webm,test-history/**/*.mp4"` to convert them to LFS pointers before pushing.

If no test-history runs exist (e.g., no emulator was available), skip this step. Don't fail the release for missing test evidence.

## Step 6: Close Fixed Issues

Scan the changelog commits for issue references (`#N`, `fix(#N)`, `feat(#N)`). For each referenced issue that is still open:

1. Check the issue is actually fixed by this release (read the issue, verify the fix commit)
2. Close with a comment linking the release, and clean up delegation labels per `.claude/process.md`:

```bash
scripts/gh-ops.sh close N --comment "Fixed in v{VERSION} ({COMMIT_SHA})"
scripts/gh-ops.sh labels N --rm bot --rm divergence
```

3. Add the release version label:

```bash
scripts/gh-ops.sh labels N --add "v{VERSION}"
```

If there's no label for this version yet, create one:

```bash
scripts/gh-ops.sh labels 0 --add "v{VERSION}"   # create label via gh-ops
# If label doesn't exist yet, create it manually (no gh-ops subcommand for label creation):
gh label create "v{VERSION}" --description "Released in v{VERSION}" --color "0E8A16"
```

Don't close issues that are only partially addressed. If a commit references an issue but only fixes part of it, leave the issue open and add a comment noting partial progress.

## Step 7: GitHub Release

Create a GitHub release with the changelog. Note: `gh release create` has no `gh-ops.sh`
wrapper yet — this is an acceptable exception for a rare, manual operation:

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

After push, rebuild the production container and verify:

```bash
scripts/container-ctl.sh restart
scripts/container-ctl.sh status
```

Check that the version meta tag matches the new release.

## Anti-Patterns

- **Don't skip validation**: "It's just a version bump" is how broken releases ship.
- **Don't amend the release commit**: If something needs fixing, make a new commit and a new patch release.
- **Don't tag without committing version bumps first**: The tag should point at the commit that contains the new version numbers.
