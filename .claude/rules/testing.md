---
paths:
  - "tests/**/*"
  - "playwright.config.*"
  - "playwright.appium.config.*"
---

# Testing

## Frozen baseline policy
- Files matching `*-baseline.spec.*` are **frozen**. Never modify test logic, assertions, or expected values.
- Only acceptable changes: fixing broken import paths after a file move, or updating infrastructure calls when a shared fixture API changes its signature (behavior must remain identical).
- Add new tests alongside baselines, never modify them. Name descriptively: `gesture-horizontal.spec.js`, not editing `gesture-scroll-baseline.spec.js`.
- If app behavior changes intentionally: add a NEW baseline, `.skip` the old one with a comment referencing the issue/PR.
- Semgrep `frozen-baseline-test` rule enforces this in pre-commit hook and CI.
- `@frozen-baseline` JSDoc tag + `nosemgrep: frozen-baseline-test` on each existing expect() in baselines.

## Test gates (run before PR)
```
scripts/test-typecheck.sh && scripts/test-lint.sh && scripts/test-unit.sh && scripts/test-headless.sh
```
Never use `npm test` (maps to full Playwright including Appium).

## Emulator/Appium tests
- MUST run via `scripts/run-appium-tests.sh`, never bare `npx playwright test --config=playwright.appium.config.js`.
- The script handles screen recording, ANR dismissal, archival to test-history/, and ffprobe validation.
- Fast-gate tests (tsc, eslint, headless playwright) are fine to run directly.
- Always run `npx tsc` after cherry-picking commits that touch TS source (compiled JS may be stale).

## Verification order for new features
1. New test first (confirm expected failures)
2. Frozen baseline second (no pollution)
3. Code change third
4. Re-test fourth

## Test patterns
- Vault tests: `cleanPage` for no-vault state, `emulatorPage` for pre-created vault.
- New Appium test files: copy baseline structure (beforeEach, helpers, tmux setup via dockerExec), extend with new assertions.
