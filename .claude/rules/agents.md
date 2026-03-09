# Agents and Delegation

- Four custom agents in `.claude/agents/`: issue-manager (haiku), delegate-scout (haiku), integrate-gater (sonnet), develop (sonnet).
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
- **Worktree cleanup after agents:** Agent worktrees in `.claude/worktrees/` persist when the agent makes changes. Run `git worktree prune` and remove stale directories before merge steps. `gh-ops.sh pr-merge` handles this automatically.
- **CWD drift:** After agent tool calls, CWD may be inside a worktree. Always use absolute paths or explicit `cd /home/dev/workspace/mobissh` before running scripts.
- Develop agent failure summaries are appended to `memory/bot-attempts.md`. Review before retrying.
