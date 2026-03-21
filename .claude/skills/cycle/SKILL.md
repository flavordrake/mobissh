---
name: cycle
description: Use when the user says "cycle", "pump", "sdlc", "next cycle", or "/cycle". Runs one full SDLC cycle — discover, prioritize, cluster, delegate, develop, gate — filtered by theme.
---

# SDLC Cycle

One pump of the outer development loop. Discovers open issues, clusters them by theme,
decomposes/merges as needed, develops fixes, and gates the results. The user gets a
summary of what shipped and what's next.

## Input

- `/cycle` — auto-detect theme from recent git log (last 20 commits)
- `/cycle "ime text entry"` — explicit theme keywords
- `/cycle --dry-run` — discover and plan only, don't develop

## Phase 0.5: Surface Unworked Issues

Before theme filtering, check for issues that may have been filed outside of sessions
and never triaged:

```bash
scripts/gh-ops.sh search "is:open no:label"
```

Any results = issues filed without labels or classification. These need:
1. Label assignment (bug/feature/chore + domain labels)
2. Body review — if minimal, ask user for scope before developing
3. Include in the triage summary with a "NEW/UNLABELED" flag

Also check for issues with no comments (never worked on):
```bash
scripts/gh-ops.sh search "is:open comments:0"
```

Present any findings to the user before proceeding to theme selection.

## Phase 1: Discover and Classify

```bash
scripts/delegate-discover.sh
scripts/delegate-classify.sh
```

Read the classified JSON. Filter to issues matching the theme (title, labels, or body
contain theme keywords). Skip `icebox`, `blocked`, and `close` classifications.

Present a triage summary:

```
Theme: "ime text entry"
Found: N issues matching theme (M total open)

| # | Title | Classification | Risk | Score |
|---|-------|---------------|------|-------|
```

## Phase 2: Cluster by Theme

Group matching issues by shared concern:
1. **File overlap** — issues touching the same source files
2. **Module proximity** — issues in the same `src/modules/` file
3. **Functional cluster** — issues describing facets of the same behavior

For each cluster:
- If 2+ issues would conflict (same files), sequence them or merge
- If a cluster exceeds bot capability (>200 lines, >5 files), decompose
- If issues are independent, develop in parallel

## Phase 3: Plan

For each cluster, determine the action:

| Action | When |
|--------|------|
| **develop** | Clear scope, bot-ready, independent |
| **merge** | 2+ issues same feature area, combined scope fits bot |
| **sequence** | Issues share files, must merge in order |
| **decompose** | Single issue too large for one pass |
| **skip** | Human-only (device testing), blocked, or icebox |

Present the plan as a table. On `--dry-run`, stop here.

```
## Plan

| Cluster | Issues | Action | Order | Notes |
|---------|--------|--------|-------|-------|
| IME state machine | #162, #170 | sequence | 1→2 | #170 depends on #162 fix |
| Preview UX | #166, #167 | merge → #166 | parallel | same preview textarea |
| Voice capture | #135 | develop | parallel | independent |
```

Wait for user approval before executing.

## Phase 4: Execute

For each approved action, in order:

### Develop (single issue)
Use the `/develop N` skill. Spawn agents with `isolation: "worktree"`.
max 4 parallel agents.

### Merge (combine issues)
1. Pick the broadest issue as primary
2. Close secondaries: `scripts/gh-ops.sh close N` + comment "Merged into #P"
3. Develop primary with combined acceptance criteria

### Sequence (ordered issues)
1. Develop first issue, wait for completion
2. If it passes, develop second issue (which can now build on the first)
3. If it fails, skip dependent issues

### Decompose
Use the `/decompose N` skill. File sub-issues, then develop them.

## Phase 5: Idle Maintenance (while agents run)

While develop agents are running in background, use the wait time productively:

1. **Integrate** — merge any completed PRs from earlier in the cycle or prior cycles
2. **Rebuild server** — `scripts/container-ctl.sh ensure` after merges
3. **Simplify** — review recently changed code for quality, fix pre-existing lint/type errors
4. **Compile learnings** — update skills, rules, project memory, docs with session insights
5. **File issues** — capture bugs and improvements noticed during the session
6. **Prepare Q&A** — draft clarifying questions for human-only/blocked issues using AskUserQuestion

This phase runs concurrently — don't block on agent completion. Check agent output
files periodically but don't poll. You'll be notified on completion.

## Phase 6: Gate

For each completed development:

```bash
scripts/integrate-gate.sh <branch-name>
```

Use **integrate-gater** agents with `isolation: "worktree"` for parallel gating.

## Phase 7: TRACE Harvesting

After all agents complete, collect and review their traces:

1. List all traces: `ls .traces/trace-*/TRACE.md`
2. For each trace:
   - Read TRACE.md — check status, knowledge seed, ambiguity gap
   - If knowledge seed is valuable: create/update memory file in
     `.claude/projects/-home-dev-workspace-mobissh/memory/`
   - If ambiguity gap reveals a missing rule: update the relevant `.claude/rules/` file
   - If pivot pattern repeats across traces: file a process improvement issue
3. Validate traces exist and are informative:
   - Develop agents without a trace directory = process violation (note in report)
   - Traces with empty TRACE.md or missing `strategy/initial_plan.md` = incomplete
   - Flag incomplete traces so the develop agent prompt can be tightened
4. Report harvested insights in the cycle summary

## Phase 8: Report

```
## Cycle Complete

Theme: "ime text entry"
Duration: Xm

| # | Title | Result | PR | Cycles | Time |
|---|-------|--------|----|--------|------|
| #162 | swipe spaces | PASS | #131 | 1/3 | 4m |
| #170 | ctrl+key preview | PASS | #132 | 2/3 | 7m |
| #135 | voice first word | FAIL | — | 3/3 | 12m |

### Next cycle candidates
Issues remaining in theme that weren't addressed this cycle.

### Failures
For each FAIL, append to `memory/bot-attempts.md`.
```

## Label Management

Per `.claude/process.md`:
- Developed: apply `bot` label
- Failed: apply `divergence`, remove `bot`
- Merged issues: close secondaries with comment
- Decomposed: apply `composite` to parent, `bot` to sub-issues

## Rules

- max 3 parallel develop agents
- Theme filter is additive — issues without theme keywords are shown but deprioritized
- Never develop `human-only` issues — report them as "needs device testing"
- Worktree cleanup deferred to release — do NOT clean while agents might be active
- Gate results determine merge readiness, but actual merging is `/integrate`'s job
- The cycle discovers and develops. Integration is a separate step — the user
  runs `/integrate` when ready to review and merge the PRs this cycle produced.

## Anti-Patterns

- Don't develop everything — prioritize by theme relevance and risk
- Don't skip the plan step — the user must approve before agents spawn
- Don't merge PRs in the cycle — that's `/integrate`'s job
- Don't retry failed issues in the same cycle — file the failure and move on
