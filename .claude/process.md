# MobiSSH Issue and Delegation Process

This document defines the label taxonomy, workflow states, and conventions that all
skills (`/delegate`, `/integrate`, `/issue`, `/release`) must follow when interacting
with GitHub issues and PRs.

## Labels

### Type (set at creation, exactly one)

| Label | Color | When |
|---|---|---|
| `bug` | `d73a4a` | Something is broken |
| `feature` | `0e8a16` | New capability |
| `enhancement` | `a2eeef` | Improvement to existing capability |
| `chore` | `cfd3d7` | Maintenance, refactoring, tooling |

### Domain (set at creation, zero or more)

| Label | Color | When |
|---|---|---|
| `ios` | `d93f0b` | iOS/Safari-specific |
| `ux` | `0075ca` | User experience, layout, mobile interaction |
| `security` | `e4e669` | Credential handling, CSP, vault, encryption |
| `image` | `c5def5` | Sixel, iTerm2, Kitty inline image passthrough |
| `touch` | `fbca04` | Touch gestures, tmux mouse, scroll, pinch |

### Delegation (managed by skills, mutually exclusive)

| Label | Color | Applied by | Meaning |
|---|---|---|---|
| `bot` | `1d76db` | `/delegate` | Bot assigned via `@claude` comment, work expected |
| `divergence` | `e99695` | `/integrate` | Bot attempted but failed; needs re-scoping or human intervention |

Lifecycle: `/delegate` applies `bot` when posting `@claude` comment. `/integrate` swaps
`bot` → `divergence` on failure. `/delegate` swaps `divergence` → `bot` on re-delegation
with new direction.

### Shape (properties of the work, zero or more)

| Label | Color | When | Required annotation |
|---|---|---|---|
| `composite` | `d4c5f9` | Issue needs decomposition into sub-issues | None |
| `spike` | `fbca04` | Next step is research, not code | None |
| `device` | `bfd4f2` | Requires real-device or emulator testing to validate | None |
| `conflict` | `f9d0c4` | Transient: file overlap detected with another in-flight issue | Comment naming the conflicting issue |
| `blocked` | `b60205` | Progress cannot move forward until blocker resolves | Comment explaining specific blocker and resolution condition |

### Retired

These labels exist on the repo but should not be applied to new issues:

| Label | Replacement |
|---|---|
| `planned` | Remove; all open issues are implicitly planned |
| `v0.3.0` | Version labels created per-release by `/release` |
| `icebox` | Close the issue with an explanation instead |

## Conventions

### `blocked` always has a comment

Never apply `blocked` without a comment explaining:
1. What specifically is blocking progress
2. Which issue, PR, or external factor is the blocker
3. What condition resolves the block

Use `gh issue edit N --add-label blocked` paired with a comment. When the blocker
resolves, remove the label and comment that it's unblocked.

### `conflict` is transient

Applied when `/delegate` detects file overlap between issues being delegated concurrently.
Resolution: either sequence the delegations (apply `blocked` to the later one with a
comment linking the earlier one) or determine they're actually independent (remove `conflict`).
`conflict` should never persist on an issue for more than one delegate/integrate cycle.

### `spike` means research-first, not human-only

An issue labeled `spike` needs investigation before code. The research itself may be
bot-delegatable if it has concrete goals (e.g., "read the xterm.js ImageAddon source and
document which escape sequences it handles"). The bot can do web research, code analysis,
and API investigation. What it cannot do is form subjective UX judgments or test on
physical devices.

### `device` means emulator or real hardware validation required

Applied when acceptance criteria cannot be verified by `tsc + eslint + vitest` alone.
`/integrate` must not merge `device`-labeled PRs without emulator or manual validation.
`/delegate` includes `device` in the delegation comment so the bot knows its PR will
face additional scrutiny.

### Bot delegation lifecycle

```
open issue
  → /delegate classifies as bot-ready
  → /delegate posts @claude comment, applies `bot` label
  → bot creates branch claude/issue-{N}-{date}-{time}
  → /integrate discovers branch, runs gates
  → gates pass → merge, close issue
  → gates fail → /integrate applies `divergence`, removes `bot`
  → /delegate analyzes failure, re-delegates with corrections → `divergence` → `bot`
```

### Attempt limits (know-when-to-quit)

| Prior attempts | Action |
|---|---|
| 0 | Delegate normally |
| 1 | Analyze failure, re-delegate with corrections |
| 2 | Re-delegate only if failure mode is clearly addressable (stale-base, trivial scope-creep) |
| 3+ | Do NOT re-delegate same scope. Decompose into different sub-tasks or classify human-only |

### Delegation template requirements

Every `@claude` comment must include:

1. **Objective** — one sentence, what to achieve
2. **Files in scope** — explicit list of files to touch (verified to exist)
3. **Acceptance criteria** — numbered, independently verifiable
4. **Context** — code snippets from current main branch, API signatures, patterns to follow
5. **Do NOT** — hard constraints (no inline styles, no new abstractions, no changes outside scope)
6. **Verify** — exact command sequence: `npx tsc --noEmit && npx eslint src/ public/ && npm test`

The bot's entire instruction set is this comment. It has no other context, no memory of
prior attempts, and no access to conversation history.

### Context freshness in delegation

The bot checks out from main HEAD at pickup time. It operates in a single shot: no
mid-task rebase, no monitoring of main during execution. To mitigate drift:

- Delegation comments include rebase-before-commit instruction when relevant
- Overlapping modules are sequenced, not delegated concurrently
- `/delegate` detects file overlap across issues and applies `conflict` for resolution

### PR merge conventions

`/integrate` merges with `--squash --delete-branch`. For orphaned branches (no PR),
create a PR first with `--label bot`, then merge. This ensures every bot contribution
has a PR record.

### Issue closing

- `/integrate` closes issues when their bot PR merges: `gh issue close N --comment "Fixed in PR #M"`
- `/release` closes issues referenced in release commits: `gh issue close N --comment "Fixed in v{VERSION}"`
- `/delegate` may close superseded issues: `gh issue close N --comment "Superseded by #M"`
- Manual close always requires an explanation comment

### Version labels

`/release` creates a `v{VERSION}` label for each release and applies it to issues closed
in that release. These are archival; do not apply them manually.

## Script inventory

Scripts that interact with GitHub (via `gh` CLI):

| Script | Used by | GitHub operations |
|---|---|---|
| `delegate-discover.sh` | `/delegate` | `gh issue list`, `gh api repos/.../branches`, `gh api repos/.../compare` |
| `delegate-classify.sh` | `/delegate` | None (reads JSON, pure classification) |
| `delegate-failure-analysis.sh` | `/delegate` | `gh repo view`, `gh api repos/.../branches`, `gh api repos/.../compare` |
| `integrate-discover.sh` | `/integrate` | `gh api repos/.../branches`, `gh api repos/.../compare` |
| `integrate-cleanup.sh` | `/delegate`, `/integrate` | `gh api -X DELETE refs/heads/...`, `gh issue comment` |
| `integrate-gate.sh` | `/integrate` | None (local git operations only) |

## Label creation commands

Run once to set up the repo (idempotent):

```bash
# New labels
gh label create bot --description "Bot assigned via @claude" --color "1d76db"
gh label create divergence --description "Bot attempted, needs re-scoping" --color "e99695"
gh label create composite --description "Needs decomposition into sub-issues" --color "d4c5f9"
gh label create spike --description "Next step is research, not code" --color "fbca04"
gh label create device --description "Requires device/emulator validation" --color "bfd4f2"
gh label create conflict --description "File overlap with in-flight issue (transient)" --color "f9d0c4"
gh label create blocked --description "Progress blocked, see comment" --color "b60205"
gh label create chore --description "Maintenance, refactoring, tooling" --color "cfd3d7"

# Retire old labels
gh label delete planned --yes
gh label delete v0.3.0 --yes
gh label delete icebox --yes
```
