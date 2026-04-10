# Candidate 1: delegate — prose classification → script extraction

## What happened
The delegate skill was born with `delegate-discover.sh` and
`delegate-classify.sh` at commit f4a32c6, but still contained
substantial prose describing classification logic, attempt counting,
label management, and raw `gh` CLI invocations. Over multiple commits
(574e552 → 7720f0f), the prose was compressed as:
- Raw `gh` calls were replaced by `gh-ops.sh` subcommands
- Classification logic prose was trimmed as the scripts matured
- Attempt-counting rules were formalized in the script

## What crystallize should find
- **Phase 1 (audit):** the SKILL-before.md contains prose describing:
  - How to count bot attempts (deterministic: parse bot-attempts.md)
  - How to check labels (deterministic: gh API call)
  - How to cross-reference bot branches (deterministic: git branch scan)
  - Raw `gh issue list`, `gh pr list` calls (should use wrapper)
  All of these are B-bucket (should be scripted).
- **Phase 2 (discover):** `delegate-discover.sh` and
  `delegate-classify.sh` already exist at this commit. Phase 2 should
  find them and recognize they cover some B-bucket operations.
- **Phase 6 (rewrite):** the before→after diff shows prose replaced by
  script calls. Crystallize's proposed rewrite should match.

## Ground truth
- B-bucket operations: attempt counting, label checking, branch
  cross-referencing, raw gh CLI calls
- Existing tools: delegate-discover.sh, delegate-classify.sh
- SKILL-before: 410 lines
- SKILL-after: 513 lines (grew because new features were added in the
  same arc, but the crystallized sections got shorter)

## Fixture files
- SKILL-before.md: delegate SKILL.md at 574e552 (pre-gh-ops)
- SKILL-after.md: delegate SKILL.md at 7720f0f (post-gh-ops)
