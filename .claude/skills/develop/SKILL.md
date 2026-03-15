---
name: develop
description: Use when the user says "develop", "work on issue", "implement issue", "fix issue N", or explicitly "/develop N". Spawns a local develop agent in a worktree to implement one or more GitHub issues. Supports batch mode ("/develop 3,9,16") with max 3 parallel agents. Without arguments, auto-proposes bot-labeled issues ranked by risk and relevance.
---

# Local Development Agent

Spawn isolated develop agents to implement GitHub issues locally. Replaces the remote
Claude bot (GitHub Actions) with faster, more reliable local execution.

## Input parsing

- `/develop 16` → single issue
- `/develop 3,9,16` → batch (max 3 parallel, rest queued)
- `/develop` (no args) → **auto-propose mode** (see below)

## Auto-propose mode

When called without arguments, propose issues to develop based on risk and relevance:

```bash
scripts/develop-propose.sh --max 5
```

This fetches open `bot`-labeled issues, scores them by:
- **Risk**: low (single file, small scope) scores higher than high (server, vault, multi-module)
- **Theme**: matches against recent git log to surface issues related to current work
- **Freshness**: no prior bot attempts scores higher
- **Blockers**: `blocked` and `device` labels reduce score

Present the ranked proposals as a table:

```
| # | Title | Risk | Score | Reason |
|---|-------|------|-------|--------|
```

Start developing the top-scored issue immediately. No approval step — the user
invoked `/develop` because they want work done, not a menu. If the top issue is
blocked, skip to the next unblocked one. For batch, develop the top 2 unblocked
in parallel.

## Pre-flight checks

For each issue number:

1. Verify issue exists and is open:
   ```bash
   scripts/gh-ops.sh fetch-issues {N}
   ```

2. Check for existing open PR on `bot/issue-{N}`:
   ```bash
   scripts/gh-ops.sh search "head:bot/issue-{N}"
   ```
   If an open PR exists, ask the user: resume (force-push) or skip?

3. Check for prior failure summaries in `.claude/projects/-home-dev-workspace-mobissh/memory/bot-attempts.md`

4. Read the delegate skill's conventions: files in scope should be identified from the
   issue body. If the issue body lacks scope, read the relevant source files to determine
   likely targets. Keep scope narrow.

## North Star: Faithful Input Representation

> "User's intended text is faithfully represented to the terminal as entered, in all cases."

For IME/input-related issues, the test infrastructure in `tests/emulator/fixtures.js` provides:
- `IntentCapture` — records what the user intended (swipe, voice, keyboard)
- `TerminalReceiver` — records what the terminal actually received
- `assertFaithful(intent, receiver, expected)` — the North Star assertion

Tests must verify **faithfulness** (intent == received), not just mechanics.

## Composing the agent prompt

For each issue, build a prompt that includes:

```
Issue #{N}: {title}

## Issue body
{full issue body from gh issue view}

## Prior failures
{section from bot-attempts.md for this issue, or "No prior attempts"}

## Files in scope
{list of files, read each to extract relevant context snippets}

## Context
{code snippets from the files showing patterns to follow}

## Constraints
- Max 3 development cycles
- Wall clock deadline: {current_time + 3600} (1 hour)
- Deadline timestamp: {unix_timestamp}
- Do NOT touch files outside scope
- Do NOT add inline styles
- Do NOT over-engineer — minimal changes only
- Follow existing code patterns
- MUST add/update headless Playwright tests for any behavior change or new feature
- MUST update existing test mocks to match the actual API being used (e.g., if code uses
  ServiceWorkerRegistration.showNotification, mock that — not new Notification())
- MUST remove or .skip tests that are no longer relevant after changes
- Major UX changes also require emulator/Appium test updates

## Verify
scripts/test-fast-gate.sh
```

## Spawning agents

Use the Agent tool with:
- `subagent_type: "general-purpose"` (custom types are broken — see `.claude/rules/agents.md`)
- `isolation: "worktree"` (MANDATORY)
- `model: "sonnet"`
- `run_in_background: true` for batch mode (2nd+ agent)

Read `.claude/agents/develop.md` for the prompt content to inline.

**Parallel limit: max 2 agents simultaneously.** If batch has >2 issues, queue the rest.
Wait for a slot to free up before spawning the next.

Single issue mode: run in foreground (not background), show results directly.

Example:
```
Agent(
  subagent_type="general-purpose",
  isolation="worktree",
  model="sonnet",
  description="develop issue 16",
  prompt="<develop.md prompt content>\n\nIssue #16: auto-populate profile name...\n\n## Issue body\n..."
)
```

## Handling results

The develop agent writes a structured result to stdout starting with `DEVELOP_RESULT:`.

### On PASS:
1. Report to user: "Issue #{N}: PR opened at {url}. Cycles: {count}/3."
2. No failure summary needed.

### On FAIL:
1. Parse the failure output (FAILURE_TYPE, SUMMARY, LAST_ERROR, FILES_TOUCHED)
2. Append to bot-attempts.md:
   ```markdown
   ## Issue #{N} — {title}
   ### Attempt {attempt_number} ({date})
   - Branch: bot/issue-{N}
   - Result: FAIL — {failure_type}
   - Cycles: {count}/3
   - Wall clock: {elapsed}s
   - Files touched: {files}
   - Summary: {summary}
   - Last error: {last_error}
   ```
3. Report to user: "Issue #{N}: FAILED after {count} cycles. {failure_type}: {summary}"

### On TIMEOUT:
Same as FAIL but note the timeout explicitly. The agent may have partial work on the branch.

## Batch mode workflow

For `/develop 3,9,16`:

1. Run pre-flight for all three issues (parallel gh calls)
2. Read bot-attempts.md once
3. Compose prompts for all three
4. Spawn agent for #3 and #9 (parallel, both in background)
5. Wait for either to complete
6. Spawn agent for #16 when a slot opens
7. Collect all results
8. Update bot-attempts.md with any failures
9. Report summary table:
   ```
   | Issue | Result | PR | Cycles | Time |
   |-------|--------|----|--------|------|
   | #3    | PASS   | #X | 1/3    | 4m   |
   | #9    | FAIL   | —  | 3/3    | 12m  |
   | #16   | PASS   | #Y | 2/3    | 7m   |
   ```

## Label management

After all agents complete:
- PASS: apply `bot` label (if not already present)
- FAIL: apply `divergence` label, remove `bot` if present
  ```bash
  scripts/gh-ops.sh labels {N} --add divergence --rm bot
  ```

## Edge cases

- Issue has no body → refuse, ask user to add scope first
- Issue is closed → skip with message
- Branch exists with uncommitted work → agent handles this (merges from main)
- gh CLI rate limited → report and retry after delay
- Agent returns no structured output → treat as FAIL with "unknown" failure type
