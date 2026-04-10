# Candidate 2: agent-trace — orphaned trace-history scripts

## What happened
Issue #230 extracted `scripts/trace-file-history.sh` and
`scripts/trace-symbol-history.sh` at commit f496bb8. These scripts
deterministically trace a file or symbol through git history,
cross-referencing issue/PR numbers from commit messages.

The SKILL.md was NEVER updated to reference these scripts. They
remain orphaned — built during problem-solving, used in that arc,
never promoted into the skill's instruction set.

## What crystallize should find
- **Phase 2 (discover):** both scripts exist in `scripts/` with clear
  CLI contracts (documented in headers). Neither is referenced by any
  SKILL.md. Classify as **orphaned**.
- **Phase 6 (rewrite):** propose adding invocations to these scripts
  where the SKILL.md currently describes git-log parsing or
  cross-referencing in prose (if it does — check).
- **Bonus:** the TRACE at `.traces/trace-issue-230-*` contains the
  LLM's original output from running the git-log parsing in prose.
  If phase 5 (verify) compares the script's output to the TRACE, it
  should find inconsistencies where the LLM miscounted or missed refs.

## Ground truth
- trace-file-history.sh: orphaned, should be wired
- trace-symbol-history.sh: orphaned, should be wired
- SKILL.md: unchanged between before and after commits (scripts were
  added to scripts/ but never integrated into the skill doc)

## Fixture files
- SKILL-before.md: agent-trace SKILL.md at 54ef711 (pre-scripts)
- SKILL-after.md: same content (no change — that's the point)
- scripts-at-time.txt: listing of scripts/ at f496bb8
