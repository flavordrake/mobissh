---
name: delegate
description: Use when the user says "delegate", "assign bot work", "dispatch issues", "triage open issues", "send to bot", or explicitly "/delegate". Scans open GitHub issues, classifies which are bot-delegatable, enriches them with design direction and context, and assigns via @claude comments. Analyzes prior bot failures and decomposes large issues.
---

# Bot Work Delegation

> **Process reference:** `.claude/process.md` defines the label taxonomy, workflow states,
> and conventions that this skill must follow.

Scan open issues, classify delegatability, enrich with direction, and assign to the Claude
bot via `@claude` comments. For issues with prior failed attempts, analyze what went wrong,
decompose if needed, and re-delegate with tighter constraints.

This is the **upstream** complement to `/integrate` (which handles the downstream: gate,
validate, merge). The cycle is: delegate → bot works → integrate → learn → re-delegate.

## Execution Model

Run **foreground**. The user approves every delegation before it posts.

**Principle:** Every deterministic step runs as a script in a Task agent. Only pull results
into the main context when there is real analysis, research, or a decision to make. The
agent's job is coordination, research, prototyping, and synthesis — not data fetching.

## Scripts

| Script | Purpose |
|---|---|
| `delegate-discover.sh` | Fetch all open issues + bot branches + diff stats → JSON |
| `delegate-classify.sh` | Apply deterministic classification rules to discover output |
| `delegate-failure-analysis.sh` | Analyze a single issue's bot branch: diff, signals, failure type |
| `integrate-cleanup.sh` | Delete stale bot branches (shared with /integrate) |

## Phase 1: Discover and classify

Launch as a Task agent:

```bash
scripts/delegate-discover.sh --out /tmp/delegate-data.json
scripts/delegate-classify.sh --data /tmp/delegate-data.json > /tmp/delegate-classified.json
```

This produces `/tmp/delegate-classified.json` with every open issue classified into:

- **delegate** — clear scope, bot-ready, no prior attempts
- **already-attempted** — has bot branches, needs failure analysis before re-delegation
- **decompose** — too large or vague for one bot pass
- **human-only** — device testing, research, UX judgment, iOS-specific
- **blocked** — depends on unresolved issue
- **close** — superseded or stale

Read the classified JSON and the summary printed to stderr. This is the starting point
for all subsequent phases.

## Phase 2: Failure analysis (already-attempted issues)

For each `already-attempted` issue, launch parallel Task agents:

```bash
scripts/delegate-failure-analysis.sh <issue-number> --data /tmp/delegate-data.json
```

Each outputs JSON with: `failure_type`, `signals`, `diff_sample`, `filenames`, `attempts`.

Deterministic failure types from the script:
- **over-engineered** — diff > 200 lines or > 5 files
- **small-testable** — diff <= 100 lines, <= 3 files, worth re-trying
- **stale-base** — 0 commits ahead of main

The script cannot determine these — the agent must read the diff and judge:
- **wrong-approach** — built the wrong thing (misunderstood the issue)
- **scope-creep** — fixed the issue but broke unrelated things
- **test-failure** — code is correct but tests fail for a specific reason

### Agent responsibilities in failure analysis

1. Read `diff_sample` from the script output
2. Compare the diff against the issue description — does the code address the right problem?
3. Check filenames — are there files that shouldn't have been touched?
4. For issues with 3+ attempts: identify the recurring pattern across attempts.
   What kept going wrong? Is the issue itself mis-scoped?
5. Decide: re-delegate with constraints, decompose, or classify as human-only

### Attempt count rules (know-when-to-quit)

- 1 prior attempt: analyze and re-delegate with corrections
- 2 prior attempts: re-delegate only if failure mode is clearly addressable
  (stale-base, scope-creep with obvious fix). Otherwise decompose.
- 3+ prior attempts: do NOT re-delegate the same scope. Either decompose into
  fundamentally different sub-tasks or classify as human-only.

## Phase 3: Cross-issue gap analysis

This is the agent's core value-add. Multiple issues often describe facets of the same
underlying gap. Delegating them independently produces conflicting implementations.

### Detect file overlap (conflict detection)

Before clustering, check whether any `delegate`-classified issues would touch the same
files. For each pair of issues about to be delegated:
1. Read the issue bodies to identify likely files in scope
2. If files overlap, apply `conflict` label to both and note in the plan table
3. Resolution: sequence the delegations (apply `blocked` to the later one) or determine
   they're actually independent (remove `conflict`). See `.claude/process.md` for conventions.

### Identify clusters

After classification and conflict detection, group related issues by:
- Shared modules (issues touching the same files — overlaps from conflict detection)
- Shared concern (e.g., #96 connection editor + #70 connect screen are both "connect UX")
- Dependency chains (e.g., #19 image detection → #20 image overlay → #21 ImageAddon eval)
- Shared failure pattern (e.g., multiple issues failing because of keyboard interaction)

### Research the gap

For each cluster, the agent must:

1. **Read the relevant source files** — understand the current architecture of the area
2. **Read all issue bodies in the cluster** — understand the full scope of what's needed
3. **Read failure diffs** — understand what approaches have been tried and why they failed
4. **Identify the real constraint** — why do bot attempts keep failing here? Is it:
   - Missing test infrastructure? (bot can't validate the change)
   - Unclear acceptance criteria? (issue is vague, bot guesses wrong)
   - Coupled modules? (change requires coordinated edits across files)
   - Wrong decomposition? (sub-tasks don't align with module boundaries)

### Prototype when necessary

If the gap requires a design decision the agent can make:

1. Read the code, understand the options
2. Sketch the approach (in the delegation comment, not as code)
3. Specify the exact function signatures, CSS class names, HTML structure
4. The bot implements to spec; it doesn't design

If the gap requires research the agent cannot resolve:
- Flag it as needing human input
- Document what was learned and what questions remain
- Suggest a research spike (small, time-boxed investigation)

### Synthesize into delegation plan

The output of gap analysis is:
- Which issues to delegate individually (independent, clear scope)
- Which issues to delegate as an ordered sequence (A before B)
- Which issues to decompose (and the specific sub-issues)
- Which issues need a new umbrella issue that captures the real gap
- Which issues to close (superseded by newer issues or already fixed)

## Phase 4: Compose delegation comments

For each issue approved for delegation, build a `@claude` comment.
The comment IS the bot's entire instruction set — it has no other context.

### Label management

When composing a delegation, also prepare label changes per `.claude/process.md`:

- Apply `bot` label (remove `divergence` if present for re-delegations)
- Apply `device` label if acceptance criteria require emulator/device validation
- Apply `composite` label if the issue will be decomposed (Phase 5)
- Apply `spike` label if the issue needs research before code
- Apply `conflict` label if file overlap detected with another in-flight `bot` issue
  (must include a comment naming the conflicting issue)

### Required sections

**Objective** — One sentence. What to achieve, not how.

**Files in scope** — Explicit list. Read each file first to confirm it exists and is
relevant. The bot should only touch these files.

**Acceptance criteria** — Numbered list. Each independently verifiable. Prefer criteria
that map to existing test assertions or can be checked with grep/tsc/eslint.

**Context** — Code snippets from the current main branch. API signatures the bot will
need. Patterns from adjacent code to follow. This section prevents the bot from inventing
its own patterns. Read the actual source files to produce this — do not guess.

**Do NOT** — Hard constraints:
- No inline styles (CSS classes only) — CLAUDE.md rule
- No new abstractions for one-time operations
- No `force: true` or extended timeouts in Playwright tests
- No changes outside scope list
- No emojis in code or UI text unless specifically requested
- (Add failure-specific constraints when re-delegating)

**Verify** — Exact command sequence:
```
npx tsc --noEmit && npx eslint src/ public/ && npm test
```

### Template

```
@claude

**Objective:** <one sentence>

**Files in scope:**
- `<path>` — <what to change and why>

**Do NOT touch:** <paths or "everything else">

**Acceptance criteria:**
1. <verifiable criterion>
2. All existing tests pass (`npm test`)

**Context:**
<code snippets from actual files on main>
<pattern to follow from adjacent code>

**Do NOT:**
- <constraint from project rules>
- <constraint from failure analysis>

**Verify:** `npx tsc --noEmit && npx eslint src/ public/ && npm test`
```

### Quality gate

Before posting, verify each comment against:
- Objective is one sentence, unambiguous
- Every file in scope actually exists (you read it)
- Context snippets are from current main, not stale
- Acceptance criteria are testable without manual device testing
- Expected diff < 150 lines (if not, decompose instead)

## Phase 5: Decompose large issues

For issues classified as `decompose`:

1. Read the full issue body
2. Read relevant source files to understand current architecture
3. Apply gap analysis findings from Phase 3
4. Break into 2-4 sub-issues, each:
   - Independently mergeable (no ordering dependency when possible)
   - Scoped to one module or one concern
   - Expected diff < 150 lines
   - Has clear acceptance criteria
5. Smallest/safest sub-issue first (proves the pattern)

### Filing sub-issues

For each sub-issue, file via `gh issue create` with the full `@claude` delegation
comment embedded in the issue body (not as a separate comment). This ensures the bot
picks up the task immediately.

After filing all sub-issues, comment on the parent:
```
Decomposed into: #A, #B, #C. Each is independently delegatable.
This parent issue tracks the overall feature.
```

## Phase 6: Present and confirm

Before taking any action, present the full plan:

```
| # | Title | Classification | Labels | Action | Notes |
|---|-------|---------------|--------|--------|-------|
```

The **Labels** column shows which labels will be applied/removed per `.claude/process.md`.

For already-attempted issues: include failure analysis summary.
For decompose issues: list proposed sub-issues.
For clusters: explain the gap and the delegation strategy.

**Wait for user approval.** The user may approve all, approve selectively, re-classify,
add context, or skip issues.

## Phase 7: Execute

Run approved actions as Task agents where possible:

- Post `@claude` comments: write body to `/tmp/delegate-comment-N.md`, then:
  ```bash
  scripts/gh-ops.sh comment N --body-file /tmp/delegate-comment-N.md
  ```
- Apply labels via `scripts/gh-ops.sh`:
  ```bash
  # New delegation
  scripts/gh-ops.sh labels N --add bot
  # Re-delegation (swap divergence → bot)
  scripts/gh-ops.sh labels N --rm divergence --add bot
  # Shape labels
  scripts/gh-ops.sh labels N --add device
  scripts/gh-ops.sh labels N --add spike
  scripts/gh-ops.sh labels N --add conflict --add blocked
  ```
- Create sub-issues: write body to `/tmp/sub-issue-N.md`, then:
  ```bash
  scripts/gh-file-issue.sh --title "..." --label bot --body-file /tmp/sub-issue-N.md
  ```
- Comment on parent issue linking sub-issues, apply `composite` label
- Clean up branches: `scripts/integrate-cleanup.sh --issue <N>`
- Close superseded issues:
  ```bash
  scripts/gh-ops.sh close N --comment "Superseded by #M"
  ```

Report:
```
Delegated: #X, #Y, #Z (labels: bot +device +spike as applicable)
Decomposed: #A → #A1, #A2, #A3 (parent labeled composite)
Cleaned up: N branches for issues #P, #Q
Closed: #C1 (superseded by #C2)
Skipped (human-only): #H1, #H2
Skipped (blocked): #B1 (labeled blocked, comment added)
```

## Encoded Lessons

These come from real project history. They are not suggestions — they are hard rules.

**Bot over-engineers by default.** Every delegation comment must include explicit scope
boundaries. "Only touch X and Y" is mandatory. Without it, the bot adds abstractions,
refactors adjacent code, and "improves" beyond scope.

**150-line ceiling.** The bot has never delivered a PR > 200 lines that passed integration
on the first attempt. Decompose before delegating anything larger.

**Bot doesn't run Playwright.** Acceptance criteria must be verifiable with
tsc + eslint + unit tests. Flag issues that need Playwright-only validation so
/integrate knows to run extra checks.

**Previous failure context is gold.** The bot has no memory of its own branches. When
re-delegating, include exactly what the prior attempt got wrong and why.

**One issue, one concern.** Bot PRs touching > 3 files for a "simple" fix are usually
wrong-scoped.

**Mobile UX is human-only.** Touch, gesture, keyboard, layout, viewport, biometric
features need device testing. Bot can't validate these.

**Clean before re-delegating.** Stale branches confuse integrate-discover.sh scoring.
Always clean up first.

**Context prevents invention.** Include actual code snippets from the current codebase.
When the bot sees the pattern to follow, it follows it. When it doesn't, it invents
its own (usually wrong).

**Clusters beat individual issues.** Three issues touching the same module should be
delegated as a coordinated sequence, not three independent tasks. The third bot PR
will conflict with the first two otherwise.

**Research gaps block delegation.** If an issue requires understanding that doesn't
exist yet (e.g., "how does iOS Safari handle X?"), the agent must research first and
embed the findings in the delegation comment. Don't delegate research to the bot.

## Edge Cases

- No open issues — report "No open issues to delegate"
- All issues human-only — report classification, suggest which to tackle manually
- Issue has no body — classify as human-only (needs scoping first)
- @claude comment already exists — check if stale. If prior attempt failed, post new
  comment with updated direction. If branch is fresh (< 24h), skip (work in progress).
- Issue was filed by the bot — treat identically to human-filed issues
- Rate limiting — pause, retry, report to user
