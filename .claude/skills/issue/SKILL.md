---
name: issue
description: Use when the user says "bug:", "feature:", "feat:", "fix:", "issue:", "chore:", or explicitly "/issue". File a GitHub issue without interrupting the current workflow. Run as a background Task so the main conversation continues unblocked.
---

# Issue Filing

File a GitHub issue from an in-conversation observation. The user types something like
`bug: default WSS URL is missing /ssh` and expects it handled without derailing current work.

## Execution Model

Run this as a **background Task**. The user's main workflow continues uninterrupted.
Return the issue URL when done.

## Step 1: Parse the trigger

Extract from the user's message:

| Prefix | GitHub label | Title prefix |
|---|---|---|
| bug: | bug | bug: |
| fix: | bug | fix: |
| feature: | enhancement | feature: |
| feat: | enhancement | feat: |
| chore: | chore | chore: |
| issue: | (classify from description) | (classify from description) |

If the prefix is `issue:` or `/issue`, read the description and pick the best label yourself.

Add a secondary label if the description matches a domain keyword:

| Keywords | Label |
|---|---|
| touch, gesture, swipe, pinch, scroll | touch |
| ios, safari, webkit, iphone, ipad | ios |
| security, vault, credential, encrypt | security |
| ux, ui, layout, mobile, keyboard, panel | ux |
| image, sixel, kitty, iterm | image |

## Step 2: Gather context

Build a concise issue body. No filler.

- **Context line**: one sentence on what was being worked on (branch, feature, test).
  Pull from the conversation state.
- **Description**: expand the user's observation into a clear problem statement or feature
  request. Add technical details you know (file paths, function names, config values).
- **Reproduction**: for bugs, describe how to reproduce if apparent. For features, describe
  the user need.
- **Current commit**: `git rev-parse --short HEAD`

## Step 3: Check for recent test artifacts

If `test-results/emulator/report.json` exists and was modified within 30 minutes
(`stat -c %Y` vs `date +%s`), there was a recent test run. Include relevant evidence:

1. **report.json**: parse for pass/fail summary, failed test names and error messages
2. **test-results/emulator/frames/**: list frame filenames that relate to the issue
3. **test-results/emulator/recording.mp4**: note existence and timestamp
4. **Per-test screenshots**: check `test-results/*-android-emulator/` for relevant PNGs

Only include artifacts clearly connected to the issue. If nothing is recent or relevant,
skip this section entirely.

## Step 4: Add @claude bot task (optional)

If the issue is actionable (bug with clear reproduction, feature with clear scope), append:

```
@claude <Specific instruction for what to investigate or implement.
Reference relevant files, test commands, or prior issues.>
```

Do NOT add @claude for research issues, things needing real-device validation, or
vague requests that need scoping.

## Step 5: Duplicate check and file

Before filing, check for existing issues:
```bash
gh issue list --search "<key phrase from title>" --state open --json number,title --limit 5
```

If a match exists, warn the user and ask whether to file or comment on the existing one.

File the issue using a heredoc for the body:
```bash
gh issue create --title "<prefix>: <concise title>" \
  --label "<primary>" --label "<secondary>" \
  --body "$(cat <<'ISSUE_EOF'
<composed body>
ISSUE_EOF
)"
```

## Step 6: Report back

Output: `Filed: <issue-url>`

If filing failed, report the error. Do not retry silently.

## Edge Cases

- Bare prefix with no description (e.g. just `bug:`) — ask for at least a one-phrase description
- `gh` not authenticated — report error immediately
- Label doesn't exist on repo — omit it rather than failing (gh will error on unknown labels)
