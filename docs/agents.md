# Custom Subagents

Design document for MobiSSH's custom Claude Code subagents.

## Problem

Claude Code's built-in `general-purpose` subagent does not inherit the parent session's
permission allow-list (`.claude/settings.json`). Background subagents auto-deny any tool
call not pre-approved before launch. Since there is no approval UI for background tasks,
Write and Bash calls fail silently and the agent returns asking for permissions it can
never receive.

This broke the `/issue` skill, which was designed to run as a background Task. Both
attempts (filing #158 and updating #55) failed identically:
1. Agent calls Write to create `/tmp/issue-body.md` -> denied
2. Agent calls Bash to run `scripts/gh-ops.sh version` -> denied
3. Agent returns a message requesting approval with no way to get it

The root cause: `general-purpose` is a built-in agent type with no project-specific
permission configuration. It doesn't know about `Bash(scripts/*)` or `Bash(gh *)`.

## Solution

Filesystem-based custom agents defined in `.claude/agents/`. Per the
[subagent docs](https://code.claude.com/docs/en/sub-agents), these support:
- `tools` field: explicit tool allowlist
- `permissionMode` field: `default` inherits parent's allow-list
- `skills` field: preloads skill content into agent context (no discovery needed)
- `background` field: always runs as background task
- `model` field: can use cheaper models for mechanical tasks

## Agents

### issue-manager

**Purpose:** File GitHub issues, add comments, manage labels. Executes the /issue skill.

**Why it needs its own agent:** Issue filing is mechanical (gather context, compose body,
call script) and should not block the main conversation. The /issue skill was designed
for background execution but failed with the built-in general-purpose agent.

**Decision: permissionMode `default` vs `bypassPermissions`**
Chose `default`. It inherits the parent's allow-list which already covers
`Bash(scripts/*)`, `Bash(gh *)`, Write, Read, etc. `bypassPermissions` would skip all
checks including ones we want (like preventing writes outside /tmp and the project).

**Decision: model `haiku` vs `inherit`**
Chose `haiku`. Issue filing is template-driven: parse trigger, gather version, compose
body, call script. No complex reasoning needed. Haiku is faster and cheaper.

**Decision: stdin heredoc vs Write-to-tempfile**
Both paths work. The scripts (`gh-file-issue.sh`, `gh-ops.sh`) already accept stdin.
A heredoc piped to the script (`scripts/gh-file-issue.sh <<'EOF'...`) matches
`Bash(scripts/*)` and avoids needing Write entirely. The skill documents both paths:
Write tool preferred (cleaner), heredoc as fallback.

**Tools:** Write, Bash, Read, Grep, Glob
**Skills:** issue
**Background:** true
**Model:** haiku

### delegate-scout

**Purpose:** Run the deterministic discovery and classification phases of /delegate
(Phases 1-3: discover, classify, fetch bodies, failure analysis). Returns structured
data for the main conversation to analyze and present.

**Why it needs its own agent:** Discovery involves running 3-4 scripts that each take
5-15 seconds and produce JSON. This is pure data gathering with no decisions. Running
it in background lets the user keep working while data accumulates.

**What it does NOT do:** Phase 4+ (gap analysis, plan composition, user approval,
execution) stays in the main conversation. The scout gathers; the main agent decides.

**Decision: not preloading /delegate skill**
The delegate skill is large and most of it (Phases 4-7) is irrelevant to the scout.
The agent's system prompt contains only the discovery/classification workflow.

**Tools:** Bash, Read, Grep, Glob (no Write needed, scripts output to /tmp)
**Background:** true
**Model:** haiku

### integrate-gater

**Purpose:** Run fast-gate validation on bot branches. Executes `scripts/integrate-gate.sh`
against one or more branches and returns pass/fail results.

**Why it needs its own agent:** Fast-gating involves checking out a branch, running
tsc + eslint + vitest, and restoring state. Takes 30-60 seconds per branch. Multiple
branches can be gated in parallel using separate agent instances.

**What it does NOT do:** Merge decisions, acceptance testing (emulator), label management.
Those stay in the main conversation.

**Decision: isolation `worktree`**
Considered using `isolation: worktree` so each gate runs on an isolated copy.
Not using it yet because `integrate-gate.sh` already handles stash/restore and detached
HEAD checkout. Adding worktree isolation is a future optimization if stash conflicts
become a problem.

**Tools:** Bash, Read, Grep, Glob (no Write, no Edit)
**Background:** true
**Model:** haiku

## Agents NOT created

### Full delegate agent
/delegate requires user approval at every decision point (Phase 6 plan, Phase 7
execution). Must stay foreground. The delegate-scout handles only the data-gathering
prefix.

### Full integrate agent
Merge decisions need user oversight. Must stay foreground. The integrate-gater handles
only the mechanical validation step.

### Release agent
Too consequential for background. Version bumps, changelogs, git tags, GitHub releases
all need user confirmation.

## Permission model

```
Parent session (.claude/settings.json)
  Bash(scripts/*), Bash(gh *), Bash(git *), Bash(npm *), ...
      |
      v (permissionMode: default = inherits)
Custom agent (.claude/agents/*.md)
  tools: [Write, Bash, Read, Grep, Glob]
  -> Agent can call Write (inherited allow)
  -> Agent can call Bash with scripts/* (inherited allow)
  -> Agent CANNOT call Edit (not in tools list)
```

Built-in general-purpose agent does NOT follow this inheritance path. It runs with
a blank permission slate and auto-denies everything in background mode.

## File locations

```
.claude/agents/
  issue-manager.md        # files issues, comments, labels
  delegate-scout.md       # discovery + classification data gathering
  integrate-gater.md      # fast-gate bot branches
```

## Related

- `.claude/skills/issue/SKILL.md` — updated to invoke issue-manager agent
- `.claude/skills/delegate/SKILL.md` — updated to invoke delegate-scout for Phases 1-3
- `.claude/skills/integrate/SKILL.md` — updated to invoke integrate-gater for Step 3
- `scripts/gh-file-issue.sh` — stdin + --body-file wrapper for gh issue create
- `scripts/gh-ops.sh` — comment, labels, close, search, version wrapper
- `.claude/settings.json` — parent permission allow-list that agents inherit
