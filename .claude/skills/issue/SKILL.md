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

Run this as a **background Task**. The user's main workflow continues uninterrupted.
Return the issue URL when done.

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

Do NOT apply delegation labels (`bot`, `divergence`) — those are managed by `/delegate`
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
  CODE_HASH=$(git rev-parse --short HEAD)
  # Server injects <meta name="app-version" content="version:hash"> into index.html
  SERVER_META=$(curl -sf --max-time 3 "http://localhost:${MOBISSH_PORT:-8081}/" 2>/dev/null \
    | grep -oP 'app-version"\s*content="\K[^"]+' || echo "server not responding")
  ```
  Include both in the issue body. If they differ, flag it:
  ```
  Code: abc1234 | Server: 0.1.0:def5678 (STALE — server hasn't been restarted)
  ```
  If the server isn't responding, just note the code hash and `(server not running)`.

## Step 3: Check for recent test artifacts

If `test-results/emulator/report.json` exists and was modified within 30 minutes
(`stat -c %Y` vs `date +%s`), there was a recent test run. Include relevant evidence:

1. **report.json**: parse for pass/fail summary, failed test names and error messages
2. **test-results/emulator/frames/**: list frame filenames that relate to the issue
3. **test-results/emulator/recording.mp4**: note existence and timestamp
4. **Per-test screenshots**: check `test-results/*-android-emulator/` for relevant PNGs

If a recording exists but no frames have been extracted (no `frames/` directory or it's
empty), run `bash scripts/review-recording.sh` to generate uniform frame samples. This
is useful when the issue relates to visual behavior that screenshots alone don't capture.

Only include artifacts clearly connected to the issue. If nothing is recent or relevant,
skip this section entirely.

## Step 4: Add @claude bot task (optional)

If the issue is actionable (bug with clear reproduction, feature with clear scope), append:

```
@claude <Specific instruction for what to investigate or implement.
Reference relevant files, test commands, or prior issues.>
```

Do NOT add `@claude` for research issues (`spike`), things needing real-device validation
(`device`), or vague requests that need scoping. The `/delegate` skill handles enriching
issues with full delegation context and applying the `bot` label — this step is just a
lightweight hint for obviously bot-ready issues.

## Step 5: Duplicate check and file

Before filing, check for existing issues:
```bash
gh issue list --search "<key phrase from title>" --state open --json number,title --limit 5
```

If a match exists, warn the user and ask whether to file or comment on the existing one.

File the issue using a heredoc for the body. Template:

```
Filed while working on <context> (<branch>).

<Problem statement or feature description with technical details.>

## Reproduction
<Steps to reproduce, or user need for features.>

## Version
Code: <CODE_HASH> | Server: <SERVER_META>
<If mismatched: "(STALE — server hasn't been restarted since <hash>)">
<If server down: "(server not running)">

## Test Evidence
<Only if recent artifacts exist (Step 3). Otherwise omit this section entirely.>
- Run: <pass/fail summary from report.json>
- Failed: <test names and error snippets>
- Frames: <relevant filenames from frames/ or review/>
- Recording: test-results/emulator/recording.mp4 (<timestamp>)

@claude <Specific bot instructions, if actionable (Step 4).>
```

```bash
gh issue create --title "<prefix>: <concise title>" \
  --label "<type>" --label "<domain>" --label "<shape>" \
  --body "$(cat <<'ISSUE_EOF'
<composed body per template above>
ISSUE_EOF
)"
```

Only include `--label` flags for labels that apply. Type is always one. Domain and shape
are zero or more. See `.claude/process.md` for the full label taxonomy.

## Step 6: Report back

Output: `Filed: <issue-url>`

If filing failed, report the error. Do not retry silently.

## Edge Cases

- Bare prefix with no description (e.g. just `bug:`) — ask for at least a one-phrase description
- `gh` not authenticated — report error immediately
- Only use labels defined in `.claude/process.md` — all are pre-created on the repo
