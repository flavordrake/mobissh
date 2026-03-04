# Development

## Build

Source: `src/modules/*.ts` (strict TypeScript). Compiled via `npx tsc` to `public/modules/*.js`.
Server: `server/index.js` (plain Node.js, not compiled). Start with `cd server && npm start`.

No bundler. ES modules served directly by the Node.js static file server.

## Test layers

### Headless browser (Playwright)

506 tests across 9 spec files. Covers UI rendering, navigation, vault operations, input
modes, settings, and basic gesture simulation.

```bash
scripts/test-typecheck.sh && scripts/test-lint.sh && scripts/test-unit.sh && scripts/test-headless.sh
npx playwright test --grep "vault"  # run a subset
```

The `webServer` config in `playwright.config.js` auto-starts the server.

### Android emulator (Appium)

31 tests across 7 spec files. Covers real Chrome touch gestures (scroll, horizontal swipe,
pinch-to-zoom), vault biometric flow, full user workflows, and integration validations.

```bash
scripts/run-appium-tests.sh           # full suite with recording
scripts/run-appium-tests.sh --suite smoke  # tagged subset
```

Never run Appium tests bare (`npx playwright test --config=playwright.appium.config.js`).
The script handles emulator boot, screen recording, ANR dismissal, archival, and ffprobe
validation.

Requires: Android SDK, AVD `MobiSSH_Pixel7`, Appium v2, UiAutomator2 driver.
Setup: `scripts/setup-appium.sh` (run as non-root).

### Manual device testing

Features requiring real hardware: iOS Safari, biometric vault unlock, Bluetooth keyboards,
real-world network latency. Use `scripts/run-appium-tests.sh` for Android; iOS needs manual
validation until iOS Simulator support is added (#140).

## Test conventions

**Frozen baselines.** Files matching `*-baseline.spec.*` are frozen. They capture known-correct
behavior and must not be modified. New features get new spec files alongside baselines.
Semgrep and the pre-commit hook enforce this.

**Per-test recording.** Each Appium test produces its own `.webm` file (540x1200, 12fps, 1Mbps).
Recordings archive to `test-history/appium/{timestamp}-{suite}/`.

**Worker-scoped sessions.** Appium tests use one session per Playwright worker to avoid
UiAutomator2 crashes from session churn.

## Pre-commit validation

```bash
scripts/test-typecheck.sh && scripts/test-lint.sh && scripts/test-unit.sh && scripts/test-headless.sh
```

This is the minimum gate. All bot PRs must pass this before merge.

## Bot delegation workflow

Issues are worked by the Claude Code GitHub integration via `@claude` comments on issues.

### Lifecycle

```
open issue
  -> /delegate classifies, posts @claude comment, applies `bot` label
  -> bot creates branch claude/issue-{N}-{date}-{time}, opens PR
  -> /integrate runs fast gates (tsc + eslint + vitest)
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
| `run-appium-tests.sh` | Full Appium test lifecycle (emulator, recording, archival) |
| `start-appium.sh` | Appium server lifecycle (ensure/start/stop/restart) |
| `setup-appium.sh` | One-time Appium + Android SDK setup |
| `integrate-gate.sh` | Fast gate: tsc + eslint + vitest on a branch |
| `delegate-discover.sh` | Fetch open issues + bot branches for /delegate |
| `delegate-classify.sh` | Classify issues into delegation categories |
| `delegate-fetch-bodies.sh` | Fetch issue bodies for classified issues |
| `gh-file-issue.sh` | Wrapper for `gh issue create` with stdin/body-file support |
| `gh-ops.sh` | Wrapper for `gh` comment/label/close/search/version operations |
| `setup-nginx.sh` | nginx reverse proxy configuration for subpath deployment |

All scripts have shebangs and execute permissions. Never prefix with `bash`.
