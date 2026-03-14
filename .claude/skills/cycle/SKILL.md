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
Max 2 parallel agents.

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

## Phase 5: Gate

For each completed development:

```bash
scripts/integrate-gate.sh <branch-name>
```

Use **integrate-gater** agents with `isolation: "worktree"` for parallel gating.

## Phase 6: Report

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

- Max 2 parallel develop agents
- Theme filter is additive — issues without theme keywords are shown but deprioritized
- Never develop `human-only` issues — report them as "needs device testing"
- Always run `scripts/worktree-cleanup.sh` before spawning agents
- Gate results determine merge readiness, but actual merging is `/integrate`'s job
- The cycle discovers and develops. Integration is a separate step — the user
  runs `/integrate` when ready to review and merge the PRs this cycle produced.

## Anti-Patterns

- Don't develop everything — prioritize by theme relevance and risk
- Don't skip the plan step — the user must approve before agents spawn
- Don't merge PRs in the cycle — that's `/integrate`'s job
- Don't retry failed issues in the same cycle — file the failure and move on
