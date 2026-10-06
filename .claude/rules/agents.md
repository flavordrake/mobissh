# MobiSSH Agents

devloop's `agents` rule covers agent types (`devloop:<name>`), isolation and
permissions; its `/develop` and `/cycle` skills set the 4-agent, 3-cycle, 1-hour limits.
These are the project additions.

## Project-specific constraints

- Every agent reads `.claude/constitution.md` first; pass it to every agent you spawn.
- Max 2 simultaneous integrate-gater agents.
- No `model` parameter on Agent calls (CLAUDE.md).
- Run each step of a multi-step gate (`full` in `AGENTS.md`) as its own Bash call; never `&&`-chain it.
- Always commit infra changes BEFORE delegating. Worktrees clone from HEAD, not working directory.
- Bot branches use pattern `bot/issue-{N}`. Check whether one is pushed with `scripts/run-in-repo.sh git ls-remote origin bot/issue-{N}`: `gh-ops.sh search` lists issues only, never PRs or branches.
- Bot branches get deleted during integration. Run `git remote prune origin` to clean stale tracking refs.
- Develop agent failure summaries are appended to the bot attempt log named in `AGENTS.md`. Review before retrying.
- `gh-ops.sh fetch-issues` writes one shared default file (`$MOBISSH_TMPDIR/fetched-issues.md`) that concurrent agents clobber: always pass `--out <own file>`.
- Scripts run by RELATIVE path (`scripts/x.sh`) from the agent's worktree root: the allow-list matches `Bash(scripts/*)` relative to CWD, so an absolute main-repo path is denied, and it would run main's code, not the agent's.
- Never end a turn on a pending gate, test run or Monitor. A stopped agent is never re-invoked by its own background job: run gates in the foreground (long timeout) or read the task's output file until it reports, then finish through to `DEVELOP_RESULT`.
- Develop agents in this repo additionally: run `semgrep scan --config auto` on their changed files and log real findings to the TRACE's `logs/security-findings.md` (fix trivial ones, never block on the rest); never add inline styles to `public/` HTML; never log secrets (telemetry rings and bug reports leave the device).

## Repo safety

- **Use intent-driven scripts:**
  - `scripts/bot-branch.sh {create|commit|pr|ship} ISSUE_NUM` — branch lifecycle. It hard-codes no attribution: export `BOT_COMMIT_TRAILERS` (the trailer lines your harness specifies) before `commit`/`ship`/`rescue`
  - `scripts/rescue-worktree.sh ISSUE_NUM` — extract stalled agent work
  - `scripts/worktree-cleanup.sh` — bulk cleanup at release time ONLY
  - `scripts/gh-ops.sh integrate PR ISSUE` — merge + prune
- **CWD drift:** All workflow scripts source `scripts/lib/repo-guard.sh` which detects and fixes CWD drift automatically. If you must run raw git commands, run `cd /home/dev/workspace/mobissh` first.
- **Worktree cleanup is deferred to release.** Do NOT run `worktree-cleanup.sh` while agents are active. `git worktree prune` (removes only already-deleted directories) is always safe.
- **Disk is guarded automatically.** `scripts/disk-reclaim.sh` (stale emulator qcow2, week-old `flutter_build` caches, build output inside MERGED worktrees — never a worktree itself, never unmerged work) runs from `flutter-cmd.sh` build/test, `ship-native.sh`, `gh-ops.sh integrate` and the SessionStart hook whenever `/` drops under 20G; under 5G after reclaim, builds refuse to start. If a job dies ENOSPC anyway: `scripts/disk-reclaim.sh --dry-run`, then free the rest by hand. Squash-merged worktrees are not detected as merged (ancestor check) — release cleanup covers them.
- **Agents gate INSIDE their worktree (#537).** Develop/gater agents run the gate as a RELATIVE path from their worktree root (`scripts/native-fast-gate.sh`) — NEVER the main-repo absolute path, and NEVER `git checkout` / `git reset --hard` / `git cherry-pick` the MAIN checkout to gate or commit. The worktree resolves its own deps (no pub workspace; `flutter-cmd.sh` handles XDG — verified). Touching the main checkout hijacks the orchestrator's tree and silently discards its uncommitted work.
- **Orchestrator: no git/ship while agents are active.** Do NOT run orchestrator git ops (commit/push/`ship-native.sh`/`gh-ops.sh integrate`) or hold uncommitted edits while ANY develop/gater agent is running — an agent may reset the shared checkout out from under you. Wait for all agents to complete; verify `git branch --show-current` == `main` + clean tree first. See memory `feedback_no_orchestrator_git_during_agents`.
