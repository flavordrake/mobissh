# Development

## Build

The product is the Flutter app in `native/`. Build and test it only through
`scripts/flutter-cmd.sh` / `scripts/native-fast-gate.sh` / `scripts/ship-native.sh` —
never a bare `flutter` invocation.

`server/index.js` (plain Node.js, not compiled) serves the install page, the native
artifacts, the feedback relay and the Claude Code approval bridge. There is no web
build step: #1205 retired the PWA's TypeScript sources, so `public/` ships verbatim.

## Test layers

The controlling document is `.claude/rules/testing.md`. In short:

| Tier | Command | What it covers |
|---|---|---|
| Fast gate | `scripts/native-fast-gate.sh` | bash rule tests, the `test/infra/` node:test suite, `flutter analyze`, the Flutter unit/widget suite |
| Infra only | `scripts/test-infra.sh` | `server/feedback-guard.js`, `server/manifest.js`, `scripts/notify-parse.sh`, the TRACE scripts, `scripts/termux-bootstrap.sh` |
| On-emulator | `scripts/with-fleet-emulator.sh -- scripts/native-integration-suite.sh` | connect/auth, reconnect, SFTP, IPC, lifecycle — against `native/integration_test/BASELINE.manifest` |

The emulator is a leased fleet device (CT113); `with-fleet-emulator.sh` books it for
one command and releases it afterwards.

### Manual device testing

Mobile UX features MUST be validated on real hardware before merging. The emulator
tier is necessary, not sufficient — see `feedback_device_run_not_headless_green`.

## Pre-commit validation

```bash
scripts/native-fast-gate.sh
```

This is the minimum gate, and it is what CI runs. All bot PRs must pass it before merge.

## Bot delegation workflow

Issues are worked by the Claude Code GitHub integration via `@claude` comments on issues.

### Lifecycle

```
open issue
  -> /delegate classifies, posts @claude comment, applies `bot` label
  -> bot creates branch claude/issue-{N}-{date}-{time}, opens PR
  -> /integrate runs the fast gate (native gate + eslint + coverage check)
  -> pass -> merge, close issue
  -> fail -> `divergence` label, needs re-scoping
  -> /delegate analyzes failure, re-delegates with corrections
```

### Labels

| Label | Meaning |
|---|---|
| `bot` | Bot assigned, work expected |
| `divergence` | Bot attempted, failed, needs re-scoping |
| `composite` | Too large, needs decomposition into sub-issues |
| `spike` | Research-first, not code |
| `device` | Requires emulator/device validation |
| `blocked` | Cannot proceed (comment explains why) |
| `conflict` | Transient: file overlap with another in-flight issue |

Full label taxonomy: `.claude/process.md`.

### Delegation constraints

- Bot has no memory across attempts. Each `@claude` comment is its entire instruction set.
- Delegation comments include code context from current main to prevent the bot from
  inventing its own patterns.
- 3+ failed attempts on the same scope = decompose or classify as human-only.

### Authoritative references

The process overview above is descriptive. The controlling directives are:

| Document | Controls |
|---|---|
| `.claude/process.md` | Label taxonomy, lifecycle states, conventions |
| `.claude/skills/delegate/SKILL.md` | How issues are classified, enriched, and delegated |
| `.claude/skills/integrate/SKILL.md` | How bot PRs are validated, merged, or rejected |
| `.claude/skills/issue/SKILL.md` | How issues are filed |
| `.claude/skills/release/SKILL.md` | How releases are tagged and published |

## Custom agents

Three custom subagents handle mechanical background tasks:

| Agent | Purpose | Model |
|---|---|---|
| `issue-manager` | File issues, add comments, manage labels | haiku |
| `delegate-scout` | Discover and classify open issues for /delegate | haiku |
| `integrate-gater` | Run fast gates on bot branches (isolated via git worktree) | sonnet |

Design rationale: `docs/agents.md`.

## Scripts

Key scripts in `scripts/`:

| Script | Purpose |
|---|---|
| `native-fast-gate.sh` | Fast gate: rule tests + infra tests + analyze + flutter test |
| `test-infra.sh` | The node:test infrastructure suite (`test/infra/`) |
| `with-fleet-emulator.sh` | Lease the fleet emulator for one command |
| `native-integration-suite.sh` | On-emulator acceptance against the baseline manifest |
| `integrate-gate.sh` | Fast gate a bot branch (native gate + eslint + coverage check) |
| `delegate-discover.sh` | Fetch open issues + bot branches for /delegate |
| `delegate-classify.sh` | Classify issues into delegation categories |
| `delegate-fetch-bodies.sh` | Fetch issue bodies for classified issues |
| `gh-file-issue.sh` | Wrapper for `gh issue create` with stdin/body-file support |
| `gh-ops.sh` | Wrapper for `gh` comment/label/close/search/version operations |
| `setup-nginx.sh` | nginx reverse proxy configuration for subpath deployment |

All scripts have shebangs and execute permissions. Never prefix with `bash`.
