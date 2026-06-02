# MobiSSH Agents

## Spawning patterns

| Agent | subagent_type | isolation | run_in_background |
|-------|---------------|-----------|-------------------|
| delegate-scout | general-purpose | (none) | false |
| issue-manager | general-purpose | (none) | true |
| integrate-gater | general-purpose | worktree | true |
| develop | general-purpose | worktree | true |

## Project-specific constraints

- Max 4 simultaneous develop agents. Queue the rest.
- Max 2 simultaneous integrate-gater agents.
- Develop agents have a 1-hour wall clock timeout and max 3 implementation cycles.
- `integrate-gate.sh` takes branch name as first arg, not issue number.
- Always commit infra changes BEFORE delegating. Worktrees clone from HEAD, not working directory.
- Verify commands in delegation: `scripts/test-fast-gate.sh` (never `npm test` or compound `&&` chains).
- Bot branches use pattern `bot/issue-{N}`. Develop agents create and push these.
- Bot branches get deleted during integration. Run `git remote prune origin` to clean stale tracking refs.
- Develop agent failure summaries are appended to `memory/bot-attempts.md`. Review before retrying.

## Repo safety

- **Use intent-driven scripts:**
  - `scripts/bot-branch.sh {create|commit|pr|ship} ISSUE_NUM` — branch lifecycle
  - `scripts/rescue-worktree.sh ISSUE_NUM` — extract stalled agent work
  - `scripts/worktree-cleanup.sh` — bulk cleanup at release time ONLY
  - `scripts/gh-ops.sh integrate PR ISSUE` — merge + prune
- **CWD drift:** All workflow scripts source `scripts/lib/repo-guard.sh` which detects and fixes CWD drift automatically. If you must run raw git commands, run `cd /home/dev/workspace/mobissh` first.
- **Worktree cleanup is deferred to release.** Do NOT run `worktree-cleanup.sh` while agents are active. `git worktree prune` (removes only already-deleted directories) is always safe.
- **Agents gate INSIDE their worktree (#537).** Develop/gater agents run the gate as a RELATIVE path from their worktree root (`scripts/native-fast-gate.sh`) — NEVER the main-repo absolute path, and NEVER `git checkout` / `git reset --hard` / `git cherry-pick` the MAIN checkout to gate or commit. The worktree resolves its own deps (no pub workspace; `flutter-cmd.sh` handles XDG — verified). Touching the main checkout hijacks the orchestrator's tree and silently discards its uncommitted work.
- **Orchestrator: no git/ship while agents are active.** Do NOT run orchestrator git ops (commit/push/`ship-native.sh`/`gh-ops.sh integrate`) or hold uncommitted edits while ANY develop/gater agent is running — an agent may reset the shared checkout out from under you. Wait for all agents to complete; verify `git branch --show-current` == `main` + clean tree first. See memory `feedback_no_orchestrator_git_during_agents`.
