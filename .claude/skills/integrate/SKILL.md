---
name: integrate
description: Use when the user says "integrate", "review bot PRs", "merge bot fixes", "check bot work", "triage PRs", or explicitly "/integrate". Reviews Claude bot PRs, validates them with available test infrastructure, and merges or rejects.
---

# Bot PR Integration

Review, validate, and merge PRs created by the Claude bot from `@claude` issue tasks.
Bot PRs follow the branch pattern `claude/issue-{N}-{DATE}-{TIME}`.

## Execution Model

Run **foreground**. The user wants to see triage decisions and approve merges.
Report progress per-PR: what was checked, what passed/failed, merge or reject decision.

## Step 1: Discover candidates

```bash
# Open bot PRs
gh pr list --state open --author "claude-assistant" \
  --json number,title,headRefName,additions,deletions,changedFiles,createdAt

# Recently closed without merge (might deserve retry or re-scope)
gh pr list --state closed --author "claude-assistant" \
  --json number,title,headRefName,mergedAt,closedAt --limit 10 \
  | jq '[.[] | select(.mergedAt == null)]'

# Bot branches without PRs (abandoned attempts)
git fetch --prune origin
git branch -r --list "origin/claude/*" --sort=-committerdate | head -20
```

Present the candidate list to the user with PR number, title, diff size, and age.

## Step 2: Triage by risk

Score each candidate and present integration order to the user.

**Low risk (integrate first):**
- Single file changed, <50 lines diff
- Pure CSS/style changes
- Config-only (manifest.json, meta tags, package.json)
- Has corresponding passing unit test in the diff

**Medium risk:**
- Multi-file but within one module boundary
- Adds new code paths without modifying existing ones
- Touch/gesture changes (need emulator but low blast radius)

**High risk (integrate last, or defer):**
- Modifies core connection/vault/crypto code
- Changes shared state or module interfaces
- >200 lines changed
- Touches `server/index.js`

**Auto-reject (close immediately):**
- PR contains changes for the wrong issue (seen in PR #133 — contained #102 changes instead of #66)
- Diff includes unrelated changes or scope creep beyond the linked issue
- >2 previous bot attempts for the same issue number. This triggers the know-when-to-quit
  rule: the issue needs human re-scoping, not more bot retries. Close the PR and comment
  on the issue explaining what the bot couldn't solve.

To count prior attempts for an issue:
```bash
git branch -r --list "origin/claude/issue-${ISSUE_NUM}-*" | wc -l
```

## Step 3: Fast gate

For each candidate (in priority order), checkout and run lightweight validation:

```bash
git stash --include-untracked  # preserve any local work
git fetch origin <branch>
git checkout <branch>

# Typecheck
npx tsc --noEmit

# Lint
npx eslint src/ public/

# Unit tests
npm test
```

**If any fail:** close the PR with a comment explaining the specific failure.
Do not retry — the bot can create a new attempt from the issue if re-triggered.

```bash
gh pr close <N> --comment "$(cat <<'EOF'
Closing: fast gate failed.

**tsc:** <pass or error summary>
**eslint:** <pass or error summary>
**vitest:** <pass or error summary>

The bot can retry from the issue if the root cause is addressed.
EOF
)"
```

After validation (pass or fail), return to the previous branch:
```bash
git checkout -
git stash pop 2>/dev/null || true
```

## Step 4: Acceptance gate

If the fast gate passes, run acceptance tests. Always attempt full emulator validation
first — don't silently fall back to headless.

### Bring up the emulator

`run-emulator-tests.sh` already handles emulator boot (Phase 2), server startup (Phase 1),
ADB forwarding (Phase 3), and Chrome CDP (Phase 3). It's the single entry point — don't
reimplement these steps.

But the emulator requires infrastructure that might not be present. Check prerequisites
before attempting:

```bash
# Can we even try?
if [[ ! -e /dev/kvm ]]; then
  echo "KVM not available — emulator cannot run on this machine"
  EMULATOR=false
elif ! command -v emulator &>/dev/null && ! command -v adb &>/dev/null; then
  echo "Android SDK not installed. Run: bash scripts/setup-avd.sh"
  EMULATOR=false
else
  EMULATOR=true
fi
```

If prerequisites exist, try to bring the emulator up. `run-emulator-tests.sh` boots it
if not already running (120s timeout), so just call it directly:

```bash
bash scripts/run-emulator-tests.sh
```

If the emulator is already running, this is a no-op for the boot phase — it detects
the existing device and proceeds to tests.

If boot fails (no AVD created yet), set up the AVD first:
```bash
bash scripts/setup-avd.sh   # one-time: downloads SDK components, creates AVD
bash scripts/run-emulator-tests.sh  # now boot + test
```

### With emulator (full validation)
After `run-emulator-tests.sh` completes:
1. Parse `test-results/emulator/report.json` for pass/fail summary
2. Compare against main branch results — are there regressions?
3. If the PR touches touch/gesture code, pay special attention to gesture test results
4. If the recording exists but frames haven't been extracted, run:
   ```bash
   bash scripts/review-recording.sh
   ```
   Review the extracted frames for visual regressions.

### Fallback: headless only (emulator truly unavailable)
Only use this path when KVM is missing or the machine genuinely can't host an emulator
(CI runner, remote server, etc.). This is not the preferred path.

1. Run headless Playwright tests:
   ```bash
   bash scripts/server-ctl.sh ensure
   npx playwright test --config=playwright.config.js
   ```
2. Check if the PR touches device-dependent areas. If any of these keywords appear in
   filenames or diff content, the PR **cannot be fully validated headless**:
   - Touch/gesture: `gesture`, `swipe`, `pinch`, `touch`
   - Layout/keyboard: `keyboard`, `layout`, `viewport`, `safe-area`
   - Vault biometric: `bio`, `fingerprint`, `webauthn`, `PasswordCredential`
   - PWA install: `manifest`, `sw.js`, `beforeinstallprompt`
3. Report to user: "PR #N passes headless tests but needs emulator validation for: [reasons]"
4. Do NOT merge device-dependent PRs without emulator validation. Queue them for when
   emulator becomes available.

### Production server awareness
The user often tests on the live production server while integration happens locally.
Check for version mismatch:
```bash
CODE_HASH=$(git rev-parse --short HEAD)
SERVER_META=$(curl -sf --max-time 3 "http://localhost:${MOBISSH_PORT:-8081}/" 2>/dev/null \
  | grep -oP 'app-version"\s*content="\K[^"]+' || echo "not running")
```
If the user is actively testing on production, warn before merging — the server will
need a restart to pick up the merged changes.

## Step 5: Merge or reject

### Merge criteria (ALL must be true)
- Fast gate passes (typecheck + lint + unit tests)
- Acceptance gate passes (emulator or headless, depending on availability)
- No test regressions vs main
- Diff review: no plaintext secret storage, no `force: true` Playwright hacks, no inline
  styles (prefer CSS), no `--no-verify` bypasses

```bash
gh pr merge <N> --squash --delete-branch
```

### Reject criteria (ANY one is sufficient)
- Tests fail at any gate
- Wrong scope or unrelated changes
- >2 prior bot attempts for same issue
- Introduces security anti-pattern

```bash
gh pr close <N> --comment "Closing: <clear reason with specific failure details>"
```

## Step 6: Post-merge

After each successful merge:
1. Return to main and pull:
   ```bash
   git checkout main && git pull
   ```
2. Restart server:
   ```bash
   bash scripts/server-ctl.sh restart
   ```
3. Run full test suite on main to confirm no regressions:
   ```bash
   npm test && npx playwright test --config=playwright.config.js
   ```
4. Report: "Merged PR #N (<title>). Tests: X pass. Server restarted at <hash>."

## Batch Mode

When processing multiple PRs:
- Integrate in priority order (low risk first)
- Re-run tests between each merge — do not batch merges without validation
- Stop on first systemic failure (main broken after merge)
- If main breaks: revert the last merge, report which PR caused it

## Encoded Lessons

These rules come from real project history. They are not suggestions.

- **Know when to quit**: >2 bot attempts on the same issue means the issue needs human
  re-scoping, not more bot retries. Close the PR, comment on the issue with what the bot
  couldn't solve, and move on.

- **Mobile UX must be device-tested**: touch, gesture, layout, keyboard features cannot
  be validated headless-only. If the emulator isn't available, flag the PR but do NOT merge.

- **Stale server trap**: the user tests on a running server while code changes happen.
  Always restart the server and verify the version hash after merging. A stale server
  means the user sees old behavior and files false bugs.

- **No force hacks**: if a Playwright test needs `force: true` or `timeout: 30000` to pass,
  the fix is wrong — the underlying layout or timing issue needs to be addressed.

- **Selection overlay precedent**: PR went through 6 commits, never worked on real Android,
  got feature-flagged off. Bot fixes that keep failing acceptance tests should be branched
  off rather than iterated on main.

- **No inline styles**: prefer CSS classes. This is a project rule (CLAUDE.md).

## Edge Cases

- No open bot PRs — report "No bot PRs to integrate" and check if there are orphaned
  bot branches that should be cleaned up
- Bot PR conflicts with main — close with comment, the bot will need to rebase from the issue
- User has uncommitted local changes — stash before checkout, pop after
- Emulator boot takes too long — use 120s timeout (same as run-emulator-tests.sh)
