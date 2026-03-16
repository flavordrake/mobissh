---
name: integrate
description: Use when the user says "integrate", "review bot PRs", "merge bot fixes", "check bot work", "triage PRs", or explicitly "/integrate". Reviews Claude bot PRs, validates them with available test infrastructure, and merges or rejects.
---

# Bot PR Integration

> **Process reference:** `.claude/process.md` defines the label taxonomy, workflow states,
> and conventions that this skill must follow.

Review, validate, and merge PRs created by the Claude bot from `@claude` issue tasks.
Bot PRs follow the branch pattern `claude/issue-{N}-{DATE}-{TIME}` or `bot/issue-{N}` (local develop agents).

## North Star

**Compile non-determinism into deterministic, declarative, reproducible scripts.**
Every step in the integration pipeline runs through a script. No ad-hoc bash chains.
`scripts/gh-ops.sh integrate PR ISSUE` replaces `gh pr merge && gh issue close && git pull`.
`scripts/container-ctl.sh ensure` replaces `docker compose build && docker compose up -d`.
If you're composing commands with `&&`, you've already lost — script it.

## Scripts

The integration pipeline is packaged as scripts in `scripts/`:

| Script | Purpose |
|---|---|
| `integrate-discover.sh` | List all bot branches, group by issue, count attempts, score risk. Outputs JSON. |
| `integrate-cleanup.sh` | Delete branches for over-attempted issues, comment on GitHub issues. Reads discover JSON. |
| `integrate-gate.sh` | Fast gate a single branch: calls test-typecheck, test-lint, test-unit. Stashes/restores local state. |
| `test-typecheck.sh` | TypeScript type checking (`tsc --noEmit`). |
| `test-lint.sh` | ESLint static analysis on all source directories. |
| `test-unit.sh` | Vitest unit tests (`src/**/*.test.ts`). No browser, no Playwright. |
| `test-headless.sh` | Headless Playwright tests (Pixel 7, iPhone 14, Desktop Chrome). Excludes Appium. |
| `run-appium-tests.sh` | Full Appium emulator acceptance with screen recording and archival. |
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
scripts/integrate-discover.sh > /tmp/integrate-candidates.json
```

This outputs a JSON array with each entry scored by risk:
- `reject` -- >2 attempts (know-when-to-quit rule)
- `low` -- single file, <50 lines
- `medium` -- multi-file within one module, or <100 lines across <=3 files
- `high` -- core code, >200 lines, server changes, vault/crypto
- `skip` -- branch has no commits ahead of main

Present the triage table to the user: issue number, title, attempt count, risk, diff size.
Ask the user how to proceed (evaluate candidates, clean up first, etc.).

## Step 2: Clean up rejects

```bash
scripts/integrate-cleanup.sh --file /tmp/integrate-candidates.json
```

This deletes branches for all `reject`-risk issues and comments on the GitHub issues
explaining that the bot couldn't converge and human re-scoping is needed.

After cleanup, update labels per `.claude/process.md`:
```bash
scripts/gh-ops.sh labels N --rm bot --add divergence
```

Options:
- `--dry-run` -- preview without acting
- `--issue N` -- clean up a specific issue's branches
- `--all` -- delete all bot branches (nuclear option)

## Step 3: Fast gate

For each candidate branch (in risk order: low first, then medium, then high):

```bash
scripts/integrate-gate.sh <branch-name>
```

The script:
1. Stashes any local uncommitted changes
2. Fetches and checks out the branch (detached HEAD)
3. Calls `scripts/test-typecheck.sh`, `scripts/test-lint.sh`, `scripts/test-unit.sh`
4. Reports pass/fail per gate
5. Restores the original branch and pops stash

Note: fast gate does NOT run browser tests. Headless Playwright is Step 4.

Exit code 0 = all gates passed, 1 = gate failed, 2 = setup error.

To auto-close a PR on failure:
```bash
scripts/integrate-gate.sh <branch> --close-on-fail --pr <number>
```

Run multiple fast gates in parallel using the **integrate-gater** agent
(`.claude/agents/integrate-gater.md`). **Always spawn with `isolation: "worktree"`** so
each agent gets its own git worktree and can checkout branches without conflicting.
Start with **2 parallel agents** and increase if the machine handles it well. The
original 8-agent crash was likely git lock contention (now solved by worktrees),
not pure CPU.

Example agent invocation:
```
Agent(subagent_type="general-purpose", isolation="worktree", model="sonnet", prompt="<integrate-gater prompt>", description="...")
```

Always use `general-purpose` — custom subagent_types are broken in file-based
discovery (see `.claude/rules/agents.md`). Read `.claude/agents/integrate-gater.md`
for the prompt content.

## Step 4: Acceptance gate (per-branch, headless)

Between merges, run headless Playwright to catch regressions quickly:

```bash
scripts/test-headless.sh
```

This is a regression check, not final acceptance. The full emulator acceptance run
happens once after all merges complete (Step 7).

**`device` label check:** If the issue has the `device` label (per `.claude/process.md`),
emulator or real-device validation is mandatory. Do NOT merge with headless-only results
unless the full Appium run in Step 7 will cover it.

### Production container awareness
The user tests on the production Docker container (`mobissh-prod`), not a local server.
After all merges complete, rebuild and restart the container:
```bash
scripts/container-ctl.sh restart
```
If the container is stale, the user sees old behavior and files false bugs.

## Step 5: Merge or reject

### Merge criteria (ALL must be true)
- Fast gate passes (typecheck + lint + unit tests)
- Acceptance gate passes (emulator or headless, depending on availability)
- No test regressions vs main
- **Test coverage**: PR includes new or updated tests. Check PR body for "Tests added"
  and "fail→pass" entries. A PR with zero test changes for a feature/bugfix is incomplete —
  reject with comment requesting test coverage.
- Diff review: no plaintext secret storage, no `force: true` Playwright hacks, no inline
  styles (prefer CSS), no `--no-verify` bypasses

```bash
scripts/gh-ops.sh integrate <PR-N> <issue-N>
```

This single command: merges the PR (with worktree cleanup), closes the issue,
removes the `bot` label, pulls main, and prunes stale refs. No compound `&&` chains.

For orphaned branches (no PR), create a PR first, then integrate:
```bash
scripts/gh-ops.sh pr-create --head <branch> --title "<issue title>" --body "Bot fix for #<N>" --label bot
scripts/gh-ops.sh integrate <PR-N> <issue-N>
```

### Approve-with-test-fixup (UX approved, tests outdated)

When a bot PR:
- Passes fast gate (tsc + lint + unit)
- UX/approach is approved by human review
- But headless tests fail because the UX intentionally changed (outdated assertions, not bugs)

This is NOT a rejection. The feature is correct; the test harness is outdated. Action:

1. Merge the feature PR to main (or have the bot merge from main in a test-fixup pass)
2. Use `/delegate` to post a **test-fixup** `@claude` comment on the same issue
   (see the test-fixup template in the delegate skill)
3. Keep `bot` label -- do NOT swap to `divergence`
4. The test-fixup pass verifies with full gate including `scripts/test-headless.sh`

Key distinction: **outdated != flaky**. Tests that fail because the UX intentionally
changed need their assertions updated. Tests that fail intermittently need investigation.

### Reject criteria (ANY one is sufficient)
- Tests fail at any gate AND the failures are bugs (not outdated assertions)
- Wrong scope or unrelated changes
- >2 prior bot attempts for same issue
- Introduces security anti-pattern

```bash
scripts/gh-ops.sh pr-close <N> --comment "Closing: <clear reason with specific failure details>"
scripts/gh-ops.sh labels <issue-N> --rm bot --add divergence
```

For orphaned branches (no PR), just delete the branch and update labels:
```bash
scripts/integrate-cleanup.sh --issue <N>
scripts/gh-ops.sh labels <N> --rm bot --add divergence
```

## Step 6: Post-merge (per-PR)

After each successful merge:
```bash
git checkout main
git pull
scripts/test-headless.sh
```
Report: "Merged PR #N (<title>). Headless tests: X pass."

After ALL merges complete, rebuild the production container:
```bash
scripts/container-ctl.sh restart
```

This is a regression gate between merges. The full acceptance run is Step 7.

## Step 7: Final acceptance -- Appium emulator run with recording

After ALL merges are complete, run the full Appium test suite on the emulator.
This produces a screen recording for human review of new features.

```bash
if [[ ! -e /dev/kvm ]]; then
  echo "KVM not available -- emulator cannot run on this machine"
  EMULATOR=false
elif ! command -v emulator &>/dev/null && ! command -v adb &>/dev/null; then
  echo "Android SDK not installed -- running setup..."
  scripts/setup-avd.sh
  EMULATOR=true
else
  EMULATOR=true
fi

if [ "$EMULATOR" = true ]; then
  scripts/run-appium-tests.sh
fi
```

`run-appium-tests.sh` handles the full pipeline: server startup, Docker sshd,
emulator boot, ADB forwarding, Appium server, screen recording with debug overlays,
Playwright test execution, artifact collection, and archival to `test-history/appium/`.

After the run completes:
1. Parse the HTML report in `playwright-report-appium/`
2. Check `test-results-appium/` for per-test artifacts
3. The recording is archived to `test-history/appium/<ISO-8601-timestamp>/recording.webm`
4. Extract review frames if needed: `scripts/review-recording.sh`
5. Report: "Appium acceptance: X pass, Y fail. Recording: test-history/appium/<ts>/recording.webm"

If the emulator is unavailable (no KVM, CI runner), report which PRs need emulator
validation and skip this step. Do NOT silently omit it.

## Batch Mode

When processing multiple PRs:
- Integrate in risk order (low first)
- Run headless Playwright between each merge (Step 6) -- do not batch merges without validation
- Stop on first systemic failure (main broken after merge)
- If main breaks: revert the last merge, report which PR caused it
- After all merges: run `scripts/run-appium-tests.sh` (Step 7) for final acceptance with recording

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
  the fix is wrong -- the underlying layout or timing issue needs to be addressed.

- **Selection overlay precedent**: PR went through 6 commits, never worked on real Android,
  got feature-flagged off. Bot fixes that keep failing acceptance tests should be branched
  off rather than iterated on main.

- **No inline styles**: prefer CSS classes. This is a project rule (CLAUDE.md).

- **Outdated != flaky**: When a UX change causes headless test failures, those tests need
  their assertions updated -- they aren't broken or intermittent. Use the test-fixup pass
  (approve-with-test-fixup) to delegate this to the bot rather than rejecting the feature.
  The bot can run `scripts/test-headless.sh` and fix mismatched selectors/assertions.

- **Two-pass delegation works**: Feature pass (fast gate) -> human UX review -> test-fixup
  pass (full gate including headless). This prevents the bot from guessing UX decisions
  while still automating the mechanical test updates.

## Edge Cases

- No bot branches at all -- report "No bot PRs to integrate"
- Bot PR conflicts with main -- close with comment, the bot will need to rebase
- User has uncommitted local changes -- `integrate-gate.sh` auto-stashes and restores
- Emulator boot takes too long -- 120s timeout in `run-emulator-tests.sh`
- SSH key not loaded for git fetch -- scripts use `gh api` which authenticates via `gh` token
- Stale worktrees block branch deletion -- `gh-ops.sh pr-merge` now prunes worktrees and
  removes local branches before merging. Always run `git worktree prune` before merge steps.
- CWD drift into worktree -- after agent tools run, CWD may be inside `.claude/worktrees/`.
  Always use absolute paths or explicit `cd` to the main repo before running scripts.
