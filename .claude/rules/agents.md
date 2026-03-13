# Agents and Delegation

- Four custom agents in `.claude/agents/`: issue-manager (sonnet), delegate-scout (sonnet), integrate-gater (sonnet), develop (sonnet).
- **Always spawn integrate-gater and develop with `isolation: "worktree"`.** Agents share main repo otherwise, causing git checkout conflicts.
- Max 2 simultaneous integrate-gater agents.
- Max 2 simultaneous develop agents. Queue the rest.
- Develop agents have a 1-hour wall clock timeout and max 3 implementation cycles.
- `integrate-gate.sh` takes branch name as first arg, not issue number.
- Permission allow-list uses `Bash(scripts/*)` not `Bash(bash *)`.
- Always commit infra changes (skills, agents, CLAUDE.md) BEFORE delegating. Worktrees and bot branches clone from HEAD, not working directory.
- Verify commands in delegation: `scripts/test-fast-gate.sh` (never `npm test` or compound `&&` chains).
- Bot branches use pattern `bot/issue-{N}`. Develop agents create and push these.
- Bot branches get deleted during integration. Run `git remote prune origin` to clean stale tracking refs.
- Develop agent failure summaries are appended to `memory/bot-attempts.md`. Review before retrying.

## Repo safety (critical)

- **Never use raw `rm -rf` on worktree paths.** Use `scripts/worktree-cleanup.sh` or `safe_rm_worktree` from `scripts/lib/repo-guard.sh`.
- **Never use raw `git checkout`, `git branch -D`, or `git worktree remove` after agent operations.** Use intent-driven scripts instead:
  - `scripts/bot-branch.sh {create|commit|pr|ship} ISSUE_NUM` — branch lifecycle
  - `scripts/rescue-worktree.sh ISSUE_NUM` — extract stalled agent work
  - `scripts/worktree-cleanup.sh` — safe orphan removal
  - `scripts/gh-ops.sh integrate PR ISSUE` — merge + cleanup (has guards built in)
- **CWD drift:** All workflow scripts source `scripts/lib/repo-guard.sh` which detects and fixes CWD drift automatically. If you must run raw git commands, run `cd /home/dev/workspace/mobissh` first.
- **Worktree cleanup is safe:** `worktree-cleanup.sh` and `gh-ops.sh` both use `safe_rm_worktree()` which refuses to delete the main repo or anything outside `.claude/worktrees/`.
