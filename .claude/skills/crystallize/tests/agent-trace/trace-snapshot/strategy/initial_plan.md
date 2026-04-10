# Initial Strategy

Issue: #230 — TRACE history scripts
Approach: Write three bash scripts for querying file/symbol/GitHub history.

## Plan
1. Write tests first (vitest, spawn scripts, assert output structure)
2. Implement three scripts following existing patterns (repo-guard.sh, MOBISSH_TMPDIR)
3. Run test-fast-gate.sh to verify

## Expected file changes
- `scripts/trace-file-history.sh` (new)
- `scripts/trace-symbol-history.sh` (new)
- `scripts/trace-github-search.sh` (new)
- `src/modules/__tests__/trace-scripts.test.ts` (new)

## Test strategy
- Feature type: deterministic spec (clear inputs/outputs)
- TDD approach: full — scripts have well-defined CLI args and output formats
- Test: spawn each script, verify exit codes, output structure, --help behavior
- Use this repo's own git history as test data

## Assumptions that might be wrong
- gh-ops.sh search is sufficient for GitHub search (it only searches open issues)
- git log --follow works reliably in worktrees
