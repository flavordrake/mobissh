---
name: write-tests
description: Use when tests need writing for existing code, after a code change that lacks coverage, or explicitly "/test N" or "write tests for X". Spawns an Opus agent focused purely on test design. Does NOT modify application code.
---

# Write Tests

Spawn a test-writing agent to add coverage for existing or recently changed code.
The agent writes tests only — no application code changes.

## Input

- `/test 225` — write tests for issue #225's changes
- `/test keybar scroll` — write tests for keybar scrolling behavior
- `/test src/modules/ui.ts:_attachRepeat` — write tests for a specific function
- `/test` — auto-detect what needs coverage from recent git diff

## Agent Design

Test design is harder than implementation — it requires imagining failure modes,
edge cases, and non-obvious interactions. Use Opus for this.

The agent:
1. Reads the code under test
2. Reads adjacent tests for patterns
3. Writes tests that verify behavior, not implementation details
4. Runs the tests to confirm they pass (testing existing behavior, not TDD red→green)
5. Commits test-only changes

## Spawning

```
Agent(
  subagent_type="general-purpose",
  isolation="worktree",
  description="write tests for {target}",
  prompt="<see below>"
)
```

Always `isolation: "worktree"`. Always background. Always test-only (no app code changes).

## Agent Prompt Template

```
You are a test-writing agent for MobiSSH. Your ONLY job is writing tests.
Do NOT modify application code. Test-only PR.

CRITICAL: Follow `.claude/agents/develop.md` for branch/commit workflow.
CRITICAL: Before ANY commit, verify branch is bot/test-{description}.

### Setup
git checkout -b bot/test-{description} origin/main

### What to test
{description of code/feature/function to test}

### Read first
- The source file(s) under test
- Adjacent test files for patterns (fixtures, helpers, assertions)
- `.claude/rules/ime.md` or `.claude/rules/typescript.md` for conventions

### Test principles
1. Test behavior, not implementation — what does the user see/experience?
2. Test boundaries — what happens at limits, with empty input, with null?
3. Test interactions — what happens when this feature meets another?
4. For UI: Playwright tests in tests/*.spec.js
5. For logic: Vitest tests in src/modules/__tests__/*.test.ts
6. Use existing fixtures — never duplicate mock server setup
7. Smoketests first (feature accessible), then behavior tests (feature works)

### What makes a good test
- Descriptive name that documents the expected behavior
- Single assertion per logical concern
- No force:true, no extended timeouts, no sleep-based assertions
- Tests that would catch a regression if someone broke the feature

### Do NOT
- Modify application code (ui.ts, ime.ts, connection.ts, server, etc.)
- Add npm dependencies
- Write tests for test infrastructure

### Verify
scripts/test-fast-gate.sh

### Finish
Verify branch, git add, commit, push, create PR, git checkout main
```

## Auto-detect Mode

When called without arguments, detect what needs coverage:

```bash
# Recent changes without test coverage
git log --oneline -10 | head -5  # recent commits
git diff HEAD~5 --name-only | grep -v __tests__ | grep -v spec.js  # changed source files
```

Cross-reference against test files — source files changed without corresponding
test files changed = coverage gap.

## Integration with /develop

The `/develop` skill's TDD workflow writes tests as part of implementation.
`/test` is different — it's for:
- Backfilling coverage on code that shipped without tests
- Adding regression tests after a bug is found on device
- Expanding coverage for a specific function or behavior
- Writing the test that SHOULD have been written but wasn't

## Rules

- Test-only PRs. Zero application code changes.
- Use Opus (test design > implementation difficulty).
- Worktree isolation mandatory.
- Tests must pass — they verify existing behavior, not propose new behavior.
- If a test fails, the test is wrong (existing code is the source of truth).
  Fix the test or skip it with a TODO explaining why.
