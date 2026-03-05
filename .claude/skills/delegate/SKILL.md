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
validate, merge). The cycle is: delegate -> bot works -> integrate -> learn -> re-delegate.

## Execution Model

Run **foreground**. The user approves every delegation before it posts.

**Principle:** Every deterministic step runs as a script in a Task agent. Only pull results
into the main context when there is real analysis, research, or a decision to make. The
agent's job is coordination, research, prototyping, and synthesis -- not data fetching.

## Scripts

| Script | Purpose |
|---|---|
| `delegate-discover.sh` | Fetch all open issues + bot branches + diff stats -> JSON |
| `delegate-classify.sh` | Apply deterministic classification rules to discover output |
| `delegate-failure-analysis.sh` | Analyze a single issue's bot branch: diff, signals, failure type |
| `integrate-cleanup.sh` | Delete stale bot branches (shared with /integrate) |

## Phase 1: Discover and classify

Invoke the **delegate-scout** agent (`.claude/agents/delegate-scout.md`) in the background.
It runs discovery, classification, failure analysis, and body fetching, then returns a
summary with file paths. Do NOT use the built-in `general-purpose` agent (it does not
inherit permissions; see `docs/agents.md`).

The scout runs these scripts and writes results to /tmp:

```bash
scripts/delegate-discover.sh --out /tmp/delegate-data.json
scripts/delegate-classify.sh --data /tmp/delegate-data.json > /tmp/delegate-classified.json
```

This produces `/tmp/delegate-classified.json` with every open issue classified into:

- **delegate** -- clear scope, bot-ready, no prior attempts
- **already-attempted** -- has bot branches, needs failure analysis before re-delegation
- **decompose** -- too large or vague for one bot pass
- **human-only** -- device testing, research, UX judgment, iOS-specific
- **blocked** -- depends on unresolved issue
- **icebox** -- labeled `icebox`, skip entirely (not ready for work)
- **close** -- superseded or stale

Read the classified JSON and the summary printed to stderr. This is the starting point
for all subsequent phases.

## Phase 2: Failure analysis (already-attempted issues)

For each `already-attempted` issue, launch parallel Task agents:

```bash
scripts/delegate-failure-analysis.sh <issue-number> --data /tmp/delegate-data.json
```

Each outputs JSON with: `failure_type`, `signals`, `diff_sample`, `filenames`, `attempts`.

Deterministic failure types from the script:
- **over-engineered** -- diff > 200 lines or > 5 files
- **small-testable** -- diff <= 100 lines, <= 3 files, worth re-trying
- **stale-base** -- 0 commits ahead of main

The script cannot determine these -- the agent must read the diff and judge:
- **wrong-approach** -- built the wrong thing (misunderstood the issue)
- **scope-creep** -- fixed the issue but broke unrelated things
- **test-failure** -- code is correct but tests fail for a specific reason

### Agent responsibilities in failure analysis

1. Read `diff_sample` from the script output
2. Compare the diff against the issue description -- does the code address the right problem?
3. Check filenames -- are there files that shouldn't have been touched?
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
- Shared modules (issues touching the same files -- overlaps from conflict detection)
- Shared concern (e.g., #96 connection editor + #70 connect screen are both "connect UX")
- Dependency chains (e.g., #19 image detection -> #20 image overlay -> #21 ImageAddon eval)
- Shared failure pattern (e.g., multiple issues failing because of keyboard interaction)

### Research the gap

For each cluster, the agent must:

1. **Read the relevant source files** -- understand the current architecture of the area
2. **Read all issue bodies in the cluster** -- understand the full scope of what's needed
3. **Read failure diffs** -- understand what approaches have been tried and why they failed
4. **Identify the real constraint** -- why do bot attempts keep failing here? Is it:
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

### Merge related issues

The inverse of decomposition. When multiple small issues describe facets of the same
feature area (same files, same UI region, same concern), merge them into a single
delegation rather than delegating individually. Individual delegation of tightly
coupled issues produces conflicting PRs or redundant changes.

**When to merge:**
- 2+ issues touch the same files (detected by conflict analysis)
- Issues describe different aspects of one UI component (e.g., key bar reflow + key bar
  polish + key bar accessibility are all "key bar UX")
- Combined scope stays within bot capability (merged diff < 200 lines, <= 5 files)
- No issue in the group requires human-only validation that blocks the others

**How to merge:**
1. Pick the broadest issue as the **primary** (or create a new umbrella issue)
2. Close the others with `Merged into #N for combined delegation`
3. Build a single `@claude` comment that addresses all merged concerns
4. Acceptance criteria = union of all individual issue criteria
5. The delegation comment must reference all merged issue numbers so the bot
   closes them all on merge

**When NOT to merge:**
- Issues are independently valuable and can ship separately
- Combined scope exceeds bot capability (> 200 lines or > 5 files)
- Issues are in different feature areas that happen to touch one shared file
- One issue is human-only but others are bot-ready

### Synthesize into delegation plan

The output of gap analysis is:
- Which issues to delegate individually (independent, clear scope)
- Which issues to **merge** into a single delegation (same feature area, would conflict)
- Which issues to delegate as an ordered sequence (A before B)
- Which issues to decompose (and the specific sub-issues)
- Which issues need a new umbrella issue that captures the real gap
- Which issues to close (superseded by newer issues or already fixed)

## Phase 4: Compose delegation comments

For each issue approved for delegation, build a `@claude` comment.
The comment IS the bot's entire instruction set -- it has no other context.

### Label management

When composing a delegation, also prepare label changes per `.claude/process.md`:

- Apply `bot` label (remove `divergence` if present for re-delegations)
- Apply `device` label if acceptance criteria require emulator/device validation
- Apply `composite` label if the issue will be decomposed (Phase 5)
- Apply `spike` label if the issue needs research before code
- Apply `conflict` label if file overlap detected with another in-flight `bot` issue
  (must include a comment naming the conflicting issue)

### Required sections

**Objective** -- One sentence. What to achieve, not how.

**Files in scope** -- Explicit list. Read each file first to confirm it exists and is
relevant. The bot should only touch these files.

**Acceptance criteria** -- Numbered list. Each independently verifiable. Prefer criteria
that map to existing test assertions or can be checked with grep/tsc/eslint.

**Context** -- Code snippets from the current main branch. API signatures the bot will
need. Patterns from adjacent code to follow. This section prevents the bot from inventing
its own patterns. Read the actual source files to produce this -- do not guess.

**Do NOT** -- Hard constraints:
- No inline styles (CSS classes only) -- CLAUDE.md rule
- No new abstractions for one-time operations
- No `force: true` or extended timeouts in Playwright tests
- No changes outside scope list
- No emojis in code or UI text unless specifically requested
- (Add failure-specific constraints when re-delegating)

**Verify** -- Exact command sequence:
```
scripts/test-typecheck.sh && scripts/test-lint.sh && scripts/test-unit.sh
```

### Template

```
@claude

**Objective:** <one sentence>

**Files in scope:**
- `<path>` -- <what to change and why>

**Do NOT touch:** <paths or "everything else">

**Acceptance criteria:**
1. <verifiable criterion>
2. All existing tests pass (`scripts/test-typecheck.sh && scripts/test-lint.sh && scripts/test-unit.sh`)

**Context:**
<code snippets from actual files on main>
<pattern to follow from adjacent code>

**Do NOT:**
- <constraint from project rules>
- <constraint from failure analysis>

**Prerequisites:**
1. `git fetch origin main && git merge origin/main` -- ensure your branch is up to date

**Verify:**
1. Run `/simplify` to review your changes for reuse, quality, and efficiency. Fix any issues found.
2. Run `scripts/test-typecheck.sh && scripts/test-lint.sh && scripts/test-unit.sh`
```

### Test-fixup template

Used when a bot feature has been approved by human review but headless tests fail because
the UX changed (outdated assertions, not flaky tests). This is a second pass on the same
issue -- the feature code is already on main, only test code needs updating.

```
@claude

**Objective:** Update headless Playwright tests to match the new UX from #{issue}.

**Files in scope:**
- `tests/<file>.spec.js` -- <what changed in the UX that breaks this test>
- `tests/fixtures.js` -- <if shared helpers need updating>

**Do NOT touch:** Any file outside `tests/`. Application code is correct and merged.

**Acceptance criteria:**
1. All headless Playwright tests pass (`scripts/test-headless.sh`)
2. No changes to application source (`src/`, `public/`, `server/`)
3. Test updates match the new UX behavior, not workarounds

**Context:**
<describe the UX change: what the old behavior was, what the new behavior is>
<specific DOM changes: new selectors, removed elements, changed visibility>
<code snippets from the updated application code showing new behavior>

**Do NOT:**
- Change any application code -- only test code
- Add `force: true` or extended timeouts to Playwright tests
- Skip or delete tests -- update assertions to match new behavior
- Add new test files -- update existing tests

**Prerequisites:**
1. `git fetch origin main && git merge origin/main` -- get the merged feature code

**Verify:**
1. Run `scripts/test-typecheck.sh && scripts/test-lint.sh && scripts/test-unit.sh`
2. Run `scripts/test-headless.sh` -- ALL 510 tests must pass (7 skipped is OK)
```

### Quality gate

Before posting, verify each comment against:
- Objective is one sentence, unambiguous
- Every file in scope actually exists (you read it)
- Context snippets are from current main, not stale
- Acceptance criteria are testable without manual device testing
- Scope is focused (one concern, clear file list)

## Phase 5: Decompose large issues

Decomposition is the inverse of merging. Use it when an issue is too large or vague
for a single bot pass. The `composite` label marks the parent; sub-issues get `bot`.

**Decompose vs Merge -- when to use which:**
- **Decompose** when one issue is too big -> break into 2-4 independently shippable sub-issues
- **Merge** when multiple small issues overlap -> combine into one delegation on a primary issue
- Never both: if you're merging small issues AND the result is too big, reconsider scope

### Analysis

For issues classified as `decompose`:

1. Read the full issue body
2. Read relevant source files to understand current architecture
3. Apply gap analysis findings from Phase 3
4. Identify natural module boundaries -- sub-issues should align with files/concerns,
   not be arbitrary line-count splits
5. Break into 2-4 sub-issues, each:
   - Independently mergeable (no ordering dependency when possible)
   - Scoped to one module or one concern
   - Has clear acceptance criteria that don't depend on other sub-issues
6. Smallest/safest sub-issue first (proves the pattern)

### Filing sub-issues

For each sub-issue, file via `gh issue create` with the full `@claude` delegation
comment embedded in the issue body (not as a separate comment). This ensures the bot
picks up the task immediately.

Title format: `feat: <parent title> -- <sub-concern>` (or `fix:`, `chore:` as appropriate).
Copy the parent's type and domain labels to each sub-issue. Add `bot` label.

### Updating the parent

After filing all sub-issues:

1. Apply `composite` label to the parent issue
2. Comment on the parent listing all sub-issues:
   ```
   Decomposed into independently delegatable sub-issues:
   - #A -- <one-line description>
   - #B -- <one-line description>
   - #C -- <one-line description>

   Each sub-issue ships independently. This parent tracks overall completion.
   ```
3. Do NOT close the parent -- it stays open as the tracking issue
4. Do NOT apply `bot` to the parent -- only sub-issues get delegated

### Ordering constraints

If sub-issues have dependencies (A must merge before B):
- Apply `blocked` label to B with a comment: "Blocked by #A -- needs A's changes on main first"
- Only delegate A immediately; B gets delegated after A merges
- Note the ordering in the parent's decomposition comment

## Phase 6: Present and confirm

Before taking any action, present the full plan:

```
| # | Title | Classification | Labels | Action | Notes |
|---|-------|---------------|--------|--------|-------|
```

The **Labels** column shows which labels will be applied/removed per `.claude/process.md`.

For already-attempted issues: include failure analysis summary.
For decompose issues: list proposed sub-issues.
For merge groups: list the issues being merged and which is the primary.
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
  # Re-delegation (swap divergence -> bot)
  scripts/gh-ops.sh labels N --rm divergence --add bot
  # Shape labels
  scripts/gh-ops.sh labels N --add device
  scripts/gh-ops.sh labels N --add spike
  scripts/gh-ops.sh labels N --add conflict --add blocked
  ```
- Decompose (create sub-issues + update parent):
  1. For each sub-issue, write body to `/tmp/sub-issue-N.md`, then:
     ```bash
     scripts/gh-file-issue.sh --title "feat: <parent> -- <sub-concern>" --label bot --label "<type>" --body-file /tmp/sub-issue-N.md
     ```
  2. Apply `composite` to parent, comment linking sub-issues:
     ```bash
     scripts/gh-ops.sh labels PARENT --add composite
     scripts/gh-ops.sh comment PARENT --body-file /tmp/decompose-comment.md
     ```
  3. Do NOT close or apply `bot` to the parent
- Clean up branches: `scripts/integrate-cleanup.sh --issue <N>`
- Close superseded issues:
  ```bash
  scripts/gh-ops.sh close N --comment "Superseded by #M"
  ```
- Merge related issues into one delegation:
  1. Pick or create the primary issue
  2. Close secondary issues:
     ```bash
     scripts/gh-ops.sh close N --comment "Merged into #P for combined delegation"
     ```
  3. Post combined `@claude` comment on primary with all merged criteria
  4. Apply `bot` label to primary

Report:
```
Delegated: #X, #Y, #Z (labels: bot +device +spike as applicable)
Merged: #A, #B, #C -> #P (combined delegation on #P, secondaries closed)
Decomposed: #D -> #D1, #D2, #D3 (parent labeled composite, sub-issues labeled bot)
  #D1 -- <description> (delegated)
  #D2 -- <description> (delegated)
  #D3 -- <description> (blocked by #D2)
Cleaned up: N branches for issues #P, #Q
Closed: #C1 (superseded by #C2)
Skipped (human-only): #H1, #H2
Skipped (blocked): #B1 (labeled blocked, comment added)
Skipped (icebox): #I1
```

## Encoded Lessons

These come from real project history. They are not suggestions -- they are hard rules.

**Bot over-engineers by default.** Every delegation comment must include explicit scope
boundaries. "Only touch X and Y" is mandatory. Without it, the bot adds abstractions,
refactors adjacent code, and "improves" beyond scope.

**Bot CAN run headless Playwright** (via `scripts/test-headless.sh`). For initial
feature work, the fast gate (tsc + eslint + unit) is sufficient. For test-fixup passes
where the bot must update test assertions to match new UX, include headless in the
verify step. The distinction: feature passes verify with fast gate only; test-fixup
passes verify with fast gate + headless.

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

**Bot can and should research.** Issues labeled `spike` that need research (API behavior,
protocol details, browser compatibility) are delegatable as research tasks. The bot
compiles findings into a `docs/` markdown file with source references. The delegation
comment should specify exact research questions and require the bot to distinguish
facts from speculation. Only flag as human-only if research requires real-device testing,
proprietary access, or judgment calls the bot can't make.

## Edge Cases

- No open issues -- report "No open issues to delegate"
- All issues human-only -- report classification, suggest which to tackle manually
- Issue has no body -- classify as human-only (needs scoping first)
- @claude comment already exists -- check if stale. If prior attempt failed, post new
  comment with updated direction. If branch is fresh (< 24h), skip (work in progress).
- Issue was filed by the bot -- treat identically to human-filed issues
- Rate limiting -- pause, retry, report to user
