---
name: issue
description: Use when the user says "bug:", "feature:", "feat:", "fix:", "issue:", "chore:", or explicitly "/issue". File a GitHub issue without interrupting the current workflow. Run as a background Task so the main conversation continues unblocked.
---

# Issue Filing

> **Process reference:** `.claude/process.md` defines the label taxonomy, workflow states,
> and conventions that this skill must follow.

File a GitHub issue from an in-conversation observation. The user types something like
`bug: default WSS URL is missing /ssh` and expects it handled without derailing current work.

## Execution Model

Spawn a `general-purpose` agent with the prompt from `.claude/agents/issue-manager.md`.
Use `model: "sonnet"`, `run_in_background: true`. Custom subagent_types are broken in
file-based discovery (see `.claude/rules/agents.md`).

Background agents auto-deny permissions not pre-approved in `settings.json`. If the
agent fails on permissions, run it in foreground instead or file directly in the main
conversation.

## Step 1: Parse the trigger

Extract from the user's message. Apply exactly one **Type** label per `.claude/process.md`:

| Prefix | Type label | Title prefix |
|---|---|---|
| bug: | `bug` | bug: |
| fix: | `bug` | fix: |
| feature: | `feature` | feature: |
| feat: | `feature` | feat: |
| chore: | `chore` | chore: |
| issue: | (classify from description) | (classify from description) |

If the prefix is `issue:` or `/issue`, read the description and pick the best type label.

Add **Domain** labels if the description matches keywords:

| Keywords | Label |
|---|---|
| touch, gesture, swipe, pinch, scroll | `touch` |
| ios, safari, webkit, iphone, ipad | `ios` |
| security, vault, credential, encrypt | `security` |
| ux, ui, layout, mobile, keyboard, panel | `ux` |
| image, sixel, kitty, iterm | `image` |

Add **Shape** labels when applicable:

| Condition | Label |
|---|---|
| Issue needs research before code can be written | `spike` |
| Issue needs emulator/device validation | `device` |
| Issue is too large for one bot pass | `composite` |

Do NOT apply delegation labels (`bot`, `divergence`) -- those are managed by `/delegate`
and `/integrate` respectively.

## Step 2: Gather context

Build a concise issue body. No filler.

- **Context line**: one sentence on what was being worked on (branch, feature, test).
  Pull from the conversation state.
- **Description**: expand the user's observation into a clear problem statement or feature
  request. Add technical details you know (file paths, function names, config values).
- **Reproduction**: for bugs, describe how to reproduce if apparent. For features, describe
  the user need.
- **Version snapshot**: capture both the code state and what the user is actually seeing.
  The user often tests on a running server while code changes happen in parallel, so these
  may differ.
  ```bash
  scripts/gh-ops.sh version
  ```
  This outputs `Code: abc1234 | Server: 0.1.0:def5678` (or `server not running`).
  If they differ, flag it as `(STALE -- server hasn't been restarted)`.

## Step 3: Check for recent test artifacts

Check for recent artifacts (modified within 30 minutes: `stat -c %Y` vs `date +%s`) and
include relevant evidence:

1. **test-results/uploads/**: bug-report bundles from the app (screenshot, telemetry rings)
2. **test-results/emulator-shots/**: emulator screenshots taken with `scripts/emu-shot.sh`
3. **/tmp/mobissh/logs/**: `native-integration-suite.log` and logcat dumps from `scripts/emu-log.sh`

For a long-press repro recording, `scripts/assemble-repro.sh` turns the frame burst
into reviewable frames.

Only include artifacts clearly connected to the issue. If nothing is recent or relevant,
skip this section entirely.

## Step 4: Suggested scope (optional)

If the issue is actionable (bug with clear reproduction, feature with clear scope), add a
short `## Suggested scope` section: the files likely involved, the test command, related
issues. Do NOT add `@claude` mentions; bot work is dispatched by `/delegate` and
`/develop` to local agents. Skip this for research issues (`spike`), things needing
real-device validation (`device`), or vague requests that need scoping.

## Step 5: Duplicate check and file

Before filing, check for existing issues:
```bash
scripts/gh-ops.sh search "<key phrase from title>"
```

If a match exists, warn the user and ask whether to file or comment on the existing one.

Write the body to a temp file, then file using the wrapper script. Body template:

```
Filed while working on <context> (<branch>).

<Problem statement or feature description with technical details.>

## Reproduction
<Steps to reproduce, or user need for features.>

## Version
<output from `scripts/gh-ops.sh version`>
<If mismatched: "(STALE -- server hasn't been restarted)">

## Test Evidence
<Only if recent artifacts exist (Step 3). Otherwise omit this section entirely.>
- Run: <suite verdict / failed test names and error snippets>
- Screenshots: <relevant paths from test-results/emulator-shots/ or the bug report>
- Bug report: <test-results/uploads/ bundle, if any>

## Suggested scope
<If actionable (Step 4). Otherwise omit.>
```

Write the composed body to a temp file, then file:

```bash
# Write body to temp file (use the Write tool, not a heredoc)
# Then file:
scripts/gh-file-issue.sh --title "<prefix>: <title>" --label "<type>" --label "<domain>" --body-file /tmp/issue-body.md
```

**Important:** Use the Write tool to create `/tmp/issue-body.md`, then call the script.
Do NOT use heredocs or `$(cat <<EOF)` in the bash command -- that's what causes
per-command approval prompts. One Write + one `scripts/gh-file-issue.sh` call.

Only include `--label` flags for labels that apply. Type is always one. Domain and shape
are zero or more. See `.claude/process.md` for the full label taxonomy.

## Step 6: Report back

Output: `Filed: <issue-url>`

If filing failed, report the error. Do not retry silently.

## Edge Cases

- Bare prefix with no description (e.g. just `bug:`) -- ask for at least a one-phrase description
- `gh` not authenticated -- report error immediately
- Only use labels defined in `.claude/process.md` -- all are pre-created on the repo
