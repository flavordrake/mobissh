# Git Integration & Merge Strategy — MobiSSH

## Branch Naming
- Develop agent branches: `bot/issue-{N}` (e.g., `bot/issue-16`)
- One branch per issue, force-pushed on retry

## Merge from Main — Do It Often
The #1 cause of integration pain is drift from main. Merge early, merge often.

### When to merge from main
- **Before starting work** — always start from current main
- **Before running tests** — ensures you're testing against latest
- **After each implementation cycle** — catch conflicts early
- **Before pushing** — minimize delta for reviewers

### How to merge
```bash
git fetch origin main
git merge origin/main --no-edit
```
**Never rebase.** Merge commits are fine. Rebase rewrites history and causes problems
with force-push tracking.

### Handling merge conflicts
1. Check which files conflict: `git diff --name-only --diff-filter=U`
2. If conflict is in YOUR files: resolve manually, keeping both your changes and main's
3. If conflict is in files you didn't touch: you have a scope problem — report in failure summary
4. After resolving: `git add <resolved-files> && git commit --no-edit`

## Commit Messages
```
fix: description of what was fixed (#N)
feat: description of what was added (#N)
chore: non-functional change (#N)
```
- Reference the issue number with `(#N)` in the commit message
- Keep the first line under 72 characters
- One commit per implementation cycle is fine (squash on merge)

## PR Creation
```bash
gh pr create --base main --head bot/issue-{N} \
  --title "Issue title" \
  --body "$(cat <<'EOF'
## Summary
- What changed and why

## Test results
- tsc: PASS
- eslint: PASS
- vitest: PASS

Closes #N
EOF
)"
```
- `Closes #N` auto-closes the issue on merge
- Always include test results in PR body
- Keep PR focused — one issue, one PR

## Keeping Diffs Small
| Metric | Target | Warning |
|---|---|---|
| Lines changed | < 100 | > 200 = over-engineering |
| Files changed | <= 3 | > 5 = scope creep |
| New files | 0-1 | > 2 = wrong abstraction |

### Strategies for small diffs
- Change the minimum needed to satisfy acceptance criteria
- Don't refactor adjacent code
- Don't add comments/docstrings to unchanged code
- Don't "improve" types that already work
- Don't add error handling for impossible cases
- If you need a helper, inline it unless it's used 3+ times

## Pre-Push Checklist
1. `git fetch origin main && git merge origin/main --no-edit`
2. `npx tsc --noEmit` — type check
3. `npx eslint src/ public/ server/ tests/` — lint
4. `npx vitest run` — unit tests
5. `git diff --stat origin/main` — review your delta
6. If delta > 200 lines or > 5 files, reconsider scope

## Recovery Patterns

### Stuck on merge conflict
```bash
git merge --abort   # Undo the merge attempt
# Re-read the conflicting file on main to understand what changed
git show origin/main:path/to/file
# Try again with understanding
```

### Accidentally committed to wrong branch
```bash
git stash
git checkout bot/issue-{N}
git stash pop
```

### Tests pass locally but fail in CI
- Check Node version (CI uses 20, local may differ)
- Check if `npx tsc` was run (compiled JS may be stale)
- Check if test depends on server being running
- Check Playwright browser versions (`npx playwright install`)
