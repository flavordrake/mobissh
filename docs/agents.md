# Subagents

MobiSSH's workflow agents come from the devloop plugin (`devloop@flavordrake`); the repo
keeps no copies of them. Spawn them as `subagent_type: devloop:<name>`; their frontmatter
sets tools, model and isolation.

| Agent | Role | Isolation | Background |
|-------|------|-----------|------------|
| `devloop:delegate-scout` | runs the delegate discovery/classification scripts, returns data | none | no (`/delegate` waits on it) |
| `devloop:issue-manager` | files issues, comments, labels for `/issue` | none | yes |
| `devloop:integrate-gater` | runs one gate tier on one bot branch | worktree | yes, max 2 at once |
| `devloop:develop` | implements one issue on `bot/issue-N`, opens the PR | worktree | yes in batch mode |
| `devloop:spec-writer`, `devloop:test-writer` | spec and failing tests for `/spec-develop` | worktree for the writer | |

Each reads `AGENTS.md` (gates, project metadata) and the repo's `CLAUDE.md`; the
project-specific rules they must also follow are in `.claude/rules/agents.md` and
`.claude/rules/workflow.md`.

## Decisions kept from the forked templates

- **Background agents need pre-approved tools.** There is no approval UI for a background
  task, so a background agent only runs what `.claude/settings.json` allows. Fix the
  settings when one fails on permissions; never drop worktree isolation to dodge it.
- **Write-to-tempfile.** Issue and PR bodies are written with the Write tool and passed
  via `--body-file` to `scripts/gh-file-issue.sh` / `scripts/gh-ops.sh`; no heredocs.
- **The scout gathers; the main agent decides.** Gap analysis, plans, approval and
  execution stay in the foreground `/delegate` session, and merge decisions in `/integrate`.

## Worktree path matching caveat

`Bash(scripts/*)` matches **relative to CWD**. An agent with worktree isolation runs in
`.claude/worktrees/agent-{id}/`; an absolute path such as
`/home/dev/workspace/mobissh/scripts/foo.sh` does not match the relative pattern, and it
would run the main checkout's code instead of the agent's. Agents use relative
`scripts/*` paths, so the gate runs from the worktree's own copy and tests its changes.
