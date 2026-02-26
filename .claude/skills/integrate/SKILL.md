---
name: integrate
description: Use when the user says "integrate", "review bot PRs", "merge bot fixes", "check bot work", "triage PRs", or explicitly "/integrate". Reviews Claude bot PRs, validates them with available test infrastructure, and merges or rejects.
---

# Bot PR Integration

Review, validate, and merge PRs created by the Claude bot from `@claude` issue tasks.
Bot PRs follow the branch pattern `claude/issue-{N}-{DATE}-{TIME}`.

## Scripts

The integration pipeline is packaged as scripts in `scripts/`:

| Script | Purpose |
|---|---|
| `integrate-discover.sh` | List all bot branches, group by issue, count attempts, score risk. Outputs JSON. |
| `integrate-cleanup.sh` | Delete branches for over-attempted issues, comment on GitHub issues. Reads discover JSON. |
| `integrate-gate.sh` | Fast gate a single branch: tsc + eslint + vitest. Stashes/restores local state. |
| `run-emulator-tests.sh` | Acceptance gate: boots emulator, starts server, runs Playwright emulator tests. |
| `server-ctl.sh` | Server lifecycle: start/stop/restart/ensure. Used post-merge. |

## Execution Model

Run **foreground**. The user wants to see triage decisions and approve merges.
Report progress per-PR: what was checked, what passed/failed, merge or reject decision.

Use the Task tool to run scripts concurrently where steps are independent (e.g., fast-gating
multiple low-risk branches in parallel). Present results to the user before proceeding to
the next step.

## Step 1: Discover and triage

```bash
bash scripts/integrate-discover.sh > /tmp/integrate-candidates.json
```

This outputs a JSON array with each entry scored by risk:
- `reject` — >2 attempts (know-when-to-quit rule)
- `low` — single file, <50 lines
- `medium` — multi-file within one module, or <100 lines across <=3 files
- `high` — core code, >200 lines, server changes, vault/crypto
- `skip` — branch has no commits ahead of main

Present the triage table to the user: issue number, title, attempt count, risk, diff size.
Ask the user how to proceed (evaluate candidates, clean up first, etc.).

## Step 2: Clean up rejects

```bash
bash scripts/integrate-cleanup.sh --file /tmp/integrate-candidates.json
```

This deletes branches for all `reject`-risk issues and comments on the GitHub issues
explaining that the bot couldn't converge and human re-scoping is needed.

Options:
- `--dry-run` — preview without acting
- `--issue N` — clean up a specific issue's branches
- `--all` — delete all bot branches (nuclear option)

## Step 3: Fast gate

For each candidate branch (in risk order: low first, then medium, then high):

```bash
bash scripts/integrate-gate.sh <branch-name>
```

The script:
1. Stashes any local uncommitted changes
2. Fetches and checks out the branch (detached HEAD)
3. Runs `npx tsc --noEmit`, `npx eslint src/ public/`, `npm test`
4. Reports pass/fail per gate
5. Restores the original branch and pops stash

Exit code 0 = all gates passed, 1 = gate failed, 2 = setup error.

To auto-close a PR on failure:
```bash
bash scripts/integrate-gate.sh <branch> --close-on-fail --pr <number>
```

Run multiple fast gates in parallel using Task agents when candidates are independent.

## Step 4: Acceptance gate

If the fast gate passes, run acceptance tests. Always attempt full emulator validation
first — don't silently fall back to headless.

### Bring up the emulator

`run-emulator-tests.sh` handles the full pipeline: emulator boot (Phase 2), server
startup (Phase 1), ADB forwarding (Phase 3), Chrome CDP (Phase 3), test execution
(Phase 4), and artifact collection (Phases 5-7). It's the single entry point.

Check prerequisites and attempt boot:

```bash
if [[ ! -e /dev/kvm ]]; then
  echo "KVM not available — emulator cannot run on this machine"
  EMULATOR=false
elif ! command -v emulator &>/dev/null && ! command -v adb &>/dev/null; then
  echo "Android SDK not installed — running setup..."
  bash scripts/setup-avd.sh
  EMULATOR=true
else
  EMULATOR=true
fi

if [ "$EMULATOR" = true ]; then
  bash scripts/run-emulator-tests.sh
fi
```

If no AVD exists, `setup-avd.sh` creates it (one-time). If the emulator is already
running, boot is a no-op — it detects the existing device.

### With emulator (full validation)
After `run-emulator-tests.sh` completes:
1. Parse `test-results/emulator/report.json` for pass/fail summary
2. Compare against main branch results — are there regressions?
3. If the PR touches touch/gesture code, pay special attention to gesture test results
4. If the recording exists but frames haven't been extracted:
   ```bash
   bash scripts/review-recording.sh
   ```

### Fallback: headless only (emulator truly unavailable)
Only use this path when KVM is missing or the machine genuinely can't host an emulator
(CI runner, remote server, etc.). This is not the preferred path.

1. Start server and run headless tests:
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
4. Do NOT merge device-dependent PRs without emulator validation. Queue them.

### Production server awareness
The user often tests on the live production server while integration happens locally.
```bash
bash scripts/server-ctl.sh status
```
If stale, warn before merging — the server will need a restart.

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

For orphaned branches (no PR), create a PR first, then merge:
```bash
gh pr create --head <branch> --title "<issue title>" --body "Bot fix for #<N>" --label bot
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

For orphaned branches (no PR), just delete the branch:
```bash
bash scripts/integrate-cleanup.sh --issue <N>
```

## Step 6: Post-merge

After each successful merge:
```bash
git checkout main && git pull
bash scripts/server-ctl.sh restart
npm test && npx playwright test --config=playwright.config.js
```
Report: "Merged PR #N (<title>). Tests: X pass. Server restarted at <hash>."

## Batch Mode

When processing multiple PRs:
- Integrate in risk order (low first)
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

- No bot branches at all — report "No bot PRs to integrate"
- Bot PR conflicts with main — close with comment, the bot will need to rebase
- User has uncommitted local changes — `integrate-gate.sh` auto-stashes and restores
- Emulator boot takes too long — 120s timeout in `run-emulator-tests.sh`
- SSH key not loaded for git fetch — scripts use `gh api` which authenticates via `gh` token
