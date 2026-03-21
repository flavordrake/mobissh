# Agents and Delegation

## Agent type reality (confirmed bugs)

Custom file-based agents (`.claude/agents/*.md`) are **broken** in Claude Code's registry
lookup. File-based discovery is unreliable — only built-in types (`general-purpose`,
`Explore`, `Plan`) and UI-created agents (`/agents` command) work reliably.

**Consequences:**
- `subagent_type: "delegate-scout"` etc. silently fall back to defaults with wrong model/permissions
- Agent frontmatter (`background`, `model`, `permissionMode`) is ignored when file discovery fails
- Built-in agent types have hardcoded behavior that frontmatter cannot override

**Rules:**
- **Always use `general-purpose`** as the subagent_type. Scope restriction goes in the prompt, not the agent type.
- Agent `.md` files in `.claude/agents/` are **prompt templates only** — read them for the prompt content, but don't rely on frontmatter for execution behavior.
- Control `run_in_background`, `isolation`, and `model` via the Agent tool call parameters.
- For read-only agents (scout, gater): include "Do NOT modify files" in the prompt.
- For write agents (develop, issue-manager): use `isolation: "worktree"`.

## Permission enforcement

- `bypassPermissions` is inherited by all subagents and cannot be overridden per-agent.
- **`deny` rules in `settings.json` survive `bypassPermissions`** — this is the only reliable enforcement.
- For fine-grained control (e.g., read-only Bash), use `PreToolUse` hooks — they fire even in bypass mode.
- Permission allow-list uses `Bash(scripts/*)` not `Bash(bash *)`.

## Agent spawning patterns

| Agent | subagent_type | isolation | run_in_background |
|-------|---------------|-----------|-------------------|
| delegate-scout | general-purpose | (none) | false |
| issue-manager | general-purpose | (none) | true |
| integrate-gater | general-purpose | worktree | true |
| develop | general-purpose | worktree | true |

**CRITICAL: Do NOT set `model` parameter on Agent tool calls.** Setting `model` (e.g.,
`model: "sonnet"`) changes the execution context and breaks permission inheritance.
The agent loses access to `Bash(scripts/*)` and other allow-list entries. Omit `model`
entirely — agents inherit the parent session's model and permissions.

- Max 4 simultaneous develop agents. Queue the rest.
- Max 2 simultaneous integrate-gater agents.
- Develop agents have a 1-hour wall clock timeout and max 3 implementation cycles.
- `integrate-gate.sh` takes branch name as first arg, not issue number.
- Always commit infra changes BEFORE delegating. Worktrees clone from HEAD, not working directory.
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
- **Worktree cleanup is deferred to release.** Do NOT run `worktree-cleanup.sh` while agents are active — it deletes their worktrees mid-operation. Worktrees are cheap (git hardlinks). Let them accumulate during development and clean in bulk at release time when nothing is in flight. `git worktree prune` (removes only already-deleted directories) is always safe.
