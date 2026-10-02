# Custom Subagents

Design document for MobiSSH's subagent prompt templates in `.claude/agents/`.

## How agents are spawned

Every agent is spawned with `subagent_type: "general-purpose"` (`.claude/rules/agents.md`);
the `.claude/agents/*.md` files are prompt templates whose body is inlined into the
prompt. Behaviour is controlled with Agent tool parameters (`isolation`,
`run_in_background`), and no `model` parameter is passed (agents inherit the parent
model and its permissions; CLAUDE.md). The frontmatter below documents each template's
intended tools and mode; it takes effect only when the template is used as a native
custom agent type.

| Agent | subagent_type | isolation | run_in_background |
|-------|---------------|-----------|-------------------|
| delegate-scout | general-purpose | (none) | false |
| issue-manager | general-purpose | (none) | true |
| integrate-gater | general-purpose | worktree | true |
| develop | general-purpose | worktree | true |

## Problem these solved

Background subagents auto-deny any tool call not pre-approved before launch; there is no
approval UI for background tasks. The `/issue` skill, designed to run in the background,
failed this way (Write to a temp body file denied, then `scripts/gh-ops.sh version`
denied). The templates pin a narrow tool list so a background agent only needs what it
was granted.

## Agents

### issue-manager

**Purpose:** File GitHub issues, add comments, manage labels. Executes the /issue skill.

**Frontmatter:** tools Write, Bash, Read, Grep, Glob; model `sonnet`;
permissionMode `bypassPermissions`; skills `issue`.

**Why its own agent:** issue filing is mechanical (gather context, compose body, call
script) and should not block the main conversation. Spawned in the background.

**Decision: `bypassPermissions`.** Background agents with `default` still get prompted
and auto-denied. Risk is bounded by the `tools` list.

**Decision: Write-to-tempfile.** The body is written with the Write tool and passed via
`--body-file` to `scripts/gh-file-issue.sh` / `scripts/gh-ops.sh`; no heredocs.

### delegate-scout

**Purpose:** Run the deterministic discovery and classification phases of /delegate
(discover, classify, failure analysis, fetch bodies). Returns structured data for the
main conversation to analyze and present.

**Frontmatter:** tools Bash, Read, Grep, Glob. No model, permissionMode or background
fields.

**What it does NOT do:** gap analysis, plan composition, user approval, execution. The
scout gathers; the main agent decides. It runs in the foreground because /delegate
waits on its results.

**Decision: not preloading /delegate.** Most of the skill is irrelevant to the scout;
its prompt contains only the discovery/classification workflow.

### integrate-gater

**Purpose:** Run `scripts/integrate-gate.sh <branch>` (native fast gate, eslint, the
source/test coverage check) on one bot branch and report the result.

**Frontmatter:** tools Bash, Read; model `sonnet`; permissionMode `bypassPermissions`.

**What it does NOT do:** merge decisions, on-emulator acceptance, label management.

**Decision: isolation `worktree`.** Each gater gets its own copy of the repo. The gate
script detects worktree mode (`git rev-parse --git-dir` vs `--git-common-dir`) and skips
stash/restore. This removed git lock contention between parallel gaters. Max 2 at once.

### develop

**Purpose:** Implement one GitHub issue end to end on `bot/issue-N`: TDD, merge from
main, gate inside its worktree, push, open the PR, populate a TRACE. Spawned by
`/develop`.

**Frontmatter:** tools Bash, Read, Edit, Write, Glob, Grep; model `sonnet`;
permissionMode `bypassPermissions`.

**Limits:** isolation `worktree` (mandatory), max 4 in parallel, 3 implementation
cycles, 1-hour wall clock. Failures are appended to `memory/bot-attempts.md`.

## Agents NOT created

- **Full delegate agent:** /delegate needs user approval at every decision point; it stays
  foreground. The scout handles only data gathering.
- **Full integrate agent:** merge decisions need user oversight. The gater handles only
  the mechanical validation step.
- **Release agent:** version bumps, tags and GitHub releases all need user confirmation.

## Worktree path matching caveat

`Bash(scripts/*)` matches **relative to CWD**. An agent with `isolation: "worktree"`
runs in `.claude/worktrees/agent-{id}/`; an absolute path such as
`/home/dev/workspace/mobissh/scripts/foo.sh` does not match the relative pattern. Agents
are told to use relative `scripts/*` paths, and the gate must run from the worktree's
own copy so it tests the agent's changes.

## File locations

```
.claude/agents/
  issue-manager.md        # files issues, comments, labels
  delegate-scout.md       # discovery + classification data gathering
  integrate-gater.md      # gates one bot branch
  develop.md              # implements one issue on bot/issue-N
```

## Related

- `.claude/skills/issue/SKILL.md`, `.claude/skills/delegate/SKILL.md`,
  `.claude/skills/integrate/SKILL.md`, `.claude/skills/develop/SKILL.md` — the skills that
  spawn these agents
- `scripts/gh-file-issue.sh` — `--body-file` wrapper for issue creation
- `scripts/gh-ops.sh` — comment, labels, close, search, delegate, integrate, release
- `.claude/rules/agents.md` — spawning table, parallel limits, repo-safety rules
