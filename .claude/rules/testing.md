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
scripts/test-fast-gate.sh     # typecheck + lint + unit
scripts/test-headless.sh      # headless Playwright E2E
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

## Test maintenance requirements
- **Every behavior change or new feature MUST include corresponding test updates.**
  - New functionality: add headless Playwright tests covering the new behavior.
  - Changed behavior: update existing test assertions to match. Do NOT leave stale tests that pass by accident (e.g., mocking the old API while code uses a new one).
  - Removed functionality: remove or `.skip` tests that are no longer relevant.
- **Major UX changes require emulator/Appium tests** in addition to headless tests.
  - Touch, gesture, keyboard, layout, viewport, notification, and PWA features need device-level validation.
- **Mock at the right level.** If code uses `ServiceWorkerRegistration.showNotification()`, mock the SW registration — not `new Notification()`. Mismatched mocks create false passes.
- Develop agents that skip test updates are producing incomplete work. The fast gate (tsc + lint + unit) catching zero failures does not mean the change is tested.

## Native Flutter gate (#501 rewrite, `native/`) — #589 contract
The native app has its OWN gate, separate from the PWA Playwright gates above.

- **Fast gate (every commit):** `scripts/native-fast-gate.sh` = `flutter analyze` +
  `flutter test --exclude-tags integration`. It CANNOT boot an emulator, so it runs
  only headless unit + widget tests. This is necessary but NOT sufficient.
- **Integration suite (merge/release gate):** `scripts/native-integration-suite.sh`
  (or `native-fast-gate.sh --with-integration`) runs the FULL `native/integration_test/`
  suite on a booted emulator through the socat+adb-reverse bridge. These are the
  byte-flow / state-machine / lifecycle tests the fast gate EXCLUDES.
- **The rule:** any change touching the session **state machine, connect/auth,
  reconnect, multi-session, SFTP, or the UI↔task-isolate IPC** MUST pass the
  integration suite before merge. The fast gate passing is NOT enough — that is
  exactly how #539/#546/#547 and the #590 stale-shell hang shipped "green" and
  broke on device. An excluded test suite reads as coverage while gating nothing.
- **Prefer headless transition tests where possible.** If a state-transition can be
  reproduced via `InMemoryGatewayPair` (no real device), put it in `native/test/`
  so it runs in the fast gate on EVERY commit — e.g. `reconnect_shell_revive_test.dart`
  (#590), `sftp_download_reassembly_test.dart` (#591). Only behaviors that genuinely
  need a device (real socket, foreground service, host-key prompt) belong in
  `integration_test/`.
- **Never silently skip the device tier.** `native-integration-suite.sh` exits
  non-zero with "NOT VALIDATED" when no emulator is present (unless
  `--allow-no-emulator` is passed explicitly). A missing emulator must never
  masquerade as a pass.
- **Test maintenance:** a native change to a gated subsystem that adds NO new
  transition test (headless or integration) is incomplete work — same standard as
  the PWA rule above.

## Test patterns
- **Emulator tests: always use `BASE_URL` from fixtures**, never relative URLs like `page.goto('./')`. CDP on Android Chrome rejects relative URLs.
- Vault tests: `cleanPage` for no-vault state, `emulatorPage` for pre-created vault.
- New Appium test files: copy baseline structure (beforeEach, helpers, tmux setup via dockerExec), extend with new assertions.
- **Vault snapshot**: `vaultSnapshot` (worker-scoped) creates vault once per file; `emulatorPage` restores snapshot + auto-unlocks via `addInitScript` hook on `window.__appReady`. Never recreate vault per test.
- **Playwright outputDir isolation**: Every `playwright*.config.*` MUST set a dedicated `outputDir`. Playwright clears `outputDir` on each run — default `test-results/` wipes recordings, reports, and frames written by `run-emulator-tests.sh`. Current mapping:
  - `playwright.config.js` → `test-results/headless`
  - `playwright.emulator.config.js` → `test-results/playwright-emulator`
  - `playwright.appium.config.js` → `test-results-appium`
  - `playwright.browserstack.config.js` → `test-results/browserstack`
