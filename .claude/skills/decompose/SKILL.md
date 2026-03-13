# Decompose Issue

Break a large or composite GitHub issue into independently shippable sub-issues.
Returns a decomposition proposal with sub-issue scope, file lists, dependency ordering,
and test impact analysis.

## Trigger

Use when the user says "decompose", "break down", "split issue", or explicitly "/decompose N".

## Input

- `/decompose 25` — single issue number
- `/decompose` (no args) — error, require issue number

## Execution Model

Run as a **foreground** agent (Explore type) for research, then return to main context
for sub-issue filing. The agent does the heavy lifting; the main context handles GitHub
operations and user approval.

## Phase 1: Understand the issue

1. Fetch the full issue body:
   ```bash
   scripts/gh-ops.sh fetch-issues N
   ```
2. Read all files mentioned in the issue body (or inferred from the description)
3. Identify the current architecture of the affected area
4. Check for related open issues that might overlap or conflict

## Phase 2: Identify module boundaries

For each area of change described in the issue:

1. **Map to files** — which source files would be modified?
2. **Find natural boundaries** — sub-issues should align with module/file boundaries,
   not arbitrary line-count splits
3. **Check coupling** — if two changes must be in the same commit to avoid breaking
   the build, they belong in the same sub-issue
4. **Assess size** — each sub-issue should be bot-capable: <=200 lines diff, <=5 files

## Phase 3: Analyze test impact

For each proposed sub-issue:

1. **Identify affected tests** — grep test files for selectors, function names, and
   UI elements that would change
2. **Classify test changes needed:**
   - **New tests required** — new behavior with no existing coverage
   - **Assertion updates** — existing tests with outdated expectations
   - **Mock updates** — test mocks that no longer match the API
   - **No test changes** — internal refactor with existing coverage
3. **Flag headless vs device** — does this sub-issue need emulator validation?
4. **Estimate test scope** — how many test files affected, how many assertions

## Phase 4: Determine ordering

1. **Independent** — sub-issues can merge in any order (preferred)
2. **Sequential** — A must merge before B (mark B as `blocked`)
3. **Parallel-safe** — sub-issues touch different files, can be developed simultaneously

## Phase 5: Present proposal

Return a structured proposal:

```
## Decomposition: #{N} — {title}

### Sub-issue 1: {title}
- **Files**: {list with one-line description of change per file}
- **Depends on**: none | sub-issue N
- **Test impact**: {new tests | assertion updates | mock updates | none}
- **Affected tests**: {test file paths and what changes}
- **Bot-delegatable**: yes/no (with reason if no)
- **Estimated diff**: ~{N} lines, {N} files

### Sub-issue 2: {title}
...

### Ordering
{diagram or description of dependencies}

### Risks
- {anything that might cause the bot to fail}
- {cross-cutting concerns not captured by the split}
```

## Phase 6: File sub-issues (after user approval)

For each approved sub-issue:

1. Write body to `/tmp/sub-issue-{parent}_{letter}.md` (include full `@claude` delegation
   instructions with file scope, acceptance criteria, context snippets, and test requirements)
2. File via: `scripts/gh-file-issue.sh --title "feat: {parent title} — {sub-concern}" --label bot --label {type} --body-file /tmp/sub-issue-{parent}_{letter}.md`
3. For blocked sub-issues: add `blocked` label and comment via `scripts/gh-ops.sh`
4. Update parent: `scripts/gh-ops.sh labels PARENT --add composite` and
   `scripts/gh-ops.sh comment PARENT --body "Decomposed into..."`

## Rules

- Sub-issues must be independently mergeable (no half-working states on main)
- Each sub-issue must include test requirements in acceptance criteria
- Never split a UI change from its test update — they ship together
- Smallest/safest sub-issue first (proves the pattern, unblocks others)
- Max 4 sub-issues per decomposition (more means the parent needs re-scoping)
- Always use `scripts/gh-ops.sh` for labels, comments, and closures — never raw `gh`
- Present proposal via `AskUserQuestion` tool to trigger mobile notification
