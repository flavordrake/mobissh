---
name: pwa-device-testing
description: This skill should be used when the user asks to "test on device", "test on emulator", "run emulator", "launch AVD", "test PWA", "test on Android", "test on mobile", "verify on real device", "check on phone", or discusses testing a feature on an actual device or emulator rather than headless Playwright. Also use when validating features that headless browsers cannot cover (biometric, PWA install, Chrome autofill, touch gestures, password managers). Use proactively when a feature has been implemented that touches any of these capabilities.
---

# PWA Device Testing

Headless Playwright tests cover logic and layout but cannot validate:
- Chrome password manager / autofill behavior
- WebAuthn biometric (fingerprint, face)
- PWA install-to-homescreen and standalone mode
- Real touch gestures, virtual keyboard, IME
- Service worker update UX on actual Chrome
- CSS safe-area-inset rendering on notched devices

This skill provides the correct setup, known pitfalls, and ready-to-use templates for testing on real Chrome via Android emulator.

## Quick Start

```bash
# First time only:
bash scripts/setup-avd.sh

# Every session:
npm run test:emulator
```

`npm run test:emulator` (via `scripts/run-emulator-tests.sh`) handles everything: boots emulator if needed, enables Chrome debugging, sets up port forwarding, runs Playwright over CDP.

## Architecture

```
Host machine                          Android Emulator (Pixel 7, API 35)
+-----------------------+             +---------------------------+
| MobiSSH server :8081  |<--adb rev-->| Chrome tab: localhost:8081|
| Playwright test runner|--CDP:9222-->| Chrome DevTools socket    |
+-----------------------+             +---------------------------+
```

- **CDP connection**: Playwright `connectOverCDP()` to real Chrome via ADB-forwarded DevTools port
- **Port forwarding**: `adb reverse tcp:8081 tcp:8081` so emulator's localhost reaches host
- **Single worker CDP**: One CDP connection per test file, fresh tab per test

## Interaction Design Principles (learned the hard way)

### Emulator tests must be faithful proxies for human interaction

Every dialog, prompt, and overlay that appears during a test flow must be handled the way a real user would handle it: see it, understand what it's asking, and dismiss it appropriately. This includes both app-owned dialogs (host key accept, vault setup) and Chrome-native UI (save password bar, add username suggestion, notification prompt).

If a test can't click a button, a real user can't either. The test is surfacing a real UX bug.

### Never use `force: true` to work around click interception

When Playwright reports `<div class="vault-dialog">…</div> intercepts pointer events`, the correct response is to fix the CSS/layout so the button is actually clickable, NOT to bypass Playwright's actionability checks with `{ force: true }`. Using `force: true`:
- Hides real interaction bugs from the test suite
- Creates a test that passes while the actual user flow is broken
- Masks layout overflow on mobile viewports

Common causes of click interception on mobile:
- `align-items: center` on `position: fixed; inset: 0` overlays — when the dialog content is taller than the viewport, content overflows and sibling elements intercept clicks. Fix: `align-items: flex-start` + `overflow-y: auto` on the overlay, `margin: auto 0` on the dialog for vertical centering that still allows scrolling.
- Chrome-native UI (password save bar, username suggestion) appearing as a layer between your app dialog and the click target. Fix: suppress Chrome autofill on test fields with `autocomplete="off"`, pre-grant notifications, use `--disable-fre` flag.
- Keyboard pushing elements up so labels overlap buttons. Fix: ensure sufficient spacing, or scroll the button into view first.

### Feature removal is a valid outcome

The selection overlay feature (#55) went through 6+ commits, was feature-flagged off, still caused interference with core scroll behavior (#143), and was ultimately removed entirely (600 lines deleted in 0ac4010). This validates the "know when to quit" principle: if every fix introduces a new bug, the abstraction is wrong. Strip it, ship the working core, and re-approach later with a cleaner design.

### Always verify server version before asking user to test

The server caches git hash at startup. A stale server process serves stale code even after commits. Before ANY manual or emulator testing:
1. Run `server-ctl.sh ensure` (checks HEAD matches running server)
2. Verify via `curl` that the production endpoint returns the expected version
3. Suggest `?reset=1` to the user to bust service worker cache

## Critical Pitfalls (learned the hard way)

### Chrome DevTools socket requires `set-debug-app`

Play Store Chrome ships as a release build. It does NOT expose the `@chrome_devtools_remote` Unix socket by default, even with USB debugging enabled. You must run:

```bash
adb shell am set-debug-app --persistent com.android.chrome
adb shell am force-stop com.android.chrome
# then relaunch Chrome
```

Without this, `adb forward tcp:9222 localabstract:chrome_devtools_remote` connects to nothing. The `run-emulator-tests.sh` script handles this automatically.

### No `browser.newContext()` on Android Chrome

Android Chrome's CDP exposes a single default browser context. Calling `browser.newContext()` throws: `Protocol error (Target.createBrowserContext): Failed to create browser context.`

Correct pattern:
```javascript
const context = browser.contexts()[0]; // use the default
const page = await context.newPage();  // new tab within it
```

### Shared localStorage across tests

Since all tabs share the single default context, localStorage is shared. Every test fixture MUST clear localStorage AND reload before the test runs. The app reads localStorage on init (panel state, vault, profiles), so clearing alone doesn't help if the app already initialized with stale state:

```javascript
await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
await page.evaluate(() => localStorage.clear());
await page.reload({ waitUntil: 'domcontentloaded' }); // app re-inits with clean state
```

### workers: 1 is mandatory for CDP

Parallel Playwright workers each try to interact with the same single Chrome instance over CDP. This causes "Target page, context or browser has been closed" across all tests. Always set `workers: 1` in the emulator config:

```javascript
module.exports = defineConfig({
  workers: 1, // single Chrome instance via CDP
  // ...
});
```

### Inject page state AFTER navigation, not before

Any `page.evaluate()` state injection (WS spies, test globals) done before `page.goto()` gets destroyed by the navigation. Always inject on the live, already-loaded page:

```javascript
// WRONG: spy gets destroyed by goto()
await page.evaluate(() => { window.__spy = []; });
await page.goto(BASE_URL);

// RIGHT: inject after the page is loaded
await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
await page.evaluate(() => { window.__spy = []; });
```

### Use actionTimeout for fast selector failure

Without `actionTimeout`, a bad selector (e.g. `#connectBtn` that doesn't exist) waits the full test timeout (60s), then cleanup closes the page, producing a misleading "Target page closed" error. Set a short action timeout so bad selectors fail fast with the actual error:

```javascript
use: {
  actionTimeout: 10_000, // fail fast on bad selectors
}
```

### Elements may not have IDs

Don't assume HTML elements have IDs. Use semantic/structural selectors:
```javascript
// BAD: #connectBtn doesn't exist
await page.locator('#connectBtn').click();

// GOOD: target by form context + type
await page.locator('#connectForm button[type="submit"]').click();
```

### Page.screencastFrame CDP doesn't work on Android emulator

The `Page.startScreencast` / `Page.screencastFrame` CDP API returns 0 frames on Android emulator Chrome. It works on desktop Chrome but the emulator's GPU pipeline doesn't produce screencast frames. Don't rely on frame count assertions. Screenshots via `page.screenshot()` work fine as an alternative.

### Worker-scoped CDP connection is mandatory

Creating a new `connectOverCDP()` per test destabilises the DevTools socket. After ~4-5 connect/disconnect cycles, the connection drops with "Target page, context or browser has been closed." Use a worker-scoped fixture:

```javascript
cdpBrowser: [async ({}, use) => {
  const browser = await chromium.connectOverCDP(`http://127.0.0.1:${CDP_PORT}`);
  await use(browser);
  browser.close();
}, { scope: 'worker' }],
```

### Chrome nag modals block test visibility on first launch

Default emulator Chrome shows a full-screen "Turn on notifications" dialog (and sometimes sign-in or default-browser prompts) on first use. These cover your app's UI and make test screenshots useless. Three-layer defense:

1. **Pre-grant POST_NOTIFICATIONS** in the test runner script (prevents the notification modal entirely):
```bash
adb shell pm grant com.android.chrome android.permission.POST_NOTIFICATIONS 2>/dev/null || true
```

2. **Chrome command-line flags** to suppress first-run experience:
```bash
adb shell "echo '_ --disable-fre --no-first-run --no-default-browser-check' > /data/local/tmp/chrome-command-line" 2>/dev/null || true
```

3. **Dismiss any remaining modals** in the Playwright fixture before navigating to your app:
```javascript
try {
  const nagBtn = page.locator('button:has-text("No thanks"), button:has-text("Not now"), button:has-text("Skip"), [id*="negative"], [id*="dismiss"]');
  await nagBtn.first().click({ timeout: 2000 });
} catch { /* no nag modal — normal after first run */ }
```

### KVM group membership requires session reload

After `sudo usermod -aG kvm $USER`, the current shell doesn't pick up the new group. Use `sg kvm -c 'emulator ...'` or start a new login session.

### AVD config uses ` = ` (with spaces)

The `config.ini` generated by `avdmanager` uses `key = value` (space-equals-space), not `key=value`. Sed patterns without spaces silently fail and the fallback `echo` creates duplicate keys. The setup script uses a `set_avd_prop` helper that handles both formats.

### WebAuthn biometric toggle in headless test browsers

`prfAvailable()` returns `true` in Playwright's headless Chromium (PublicKeyCredential API exists) but `navigator.credentials.create()` hangs forever (no authenticator). In headless tests, uncheck the biometric toggle via `page.evaluate`:

```javascript
await page.evaluate(() => {
  const cb = document.getElementById('vaultEnableBio');
  if (cb) cb.checked = false;
});
```

The CSS toggle hides the checkbox with `opacity:0; width:0; height:0`, so Playwright's `isVisible()` returns false and `uncheck()` silently skips it. Always use `page.evaluate` for CSS-hidden form elements.

## Real SSH Integration via Docker

For features that need a live SSH connection (gestures, terminal buffer, command execution), use the Docker test-sshd container instead of WebSocket mocks:

```bash
docker compose -f docker-compose.test.yml up -d test-sshd
ssh -p 2222 testuser@localhost  # password: testpass
```

The `sshd-fixture.js` helper starts the container automatically and exposes credentials to tests. The `setupRealSSHConnection(page, sshServer)` helper in `fixtures.js` handles: vault creation, SSRF bypass for localhost, connect form fill, host key acceptance, and waiting for connected state.

## Touch Gesture Testing

Synthetic `TouchEvent` dispatch via `page.evaluate()` tests the same JS code path as real finger touches. This is more reliable than CDP `Input.dispatchTouchEvent` which behaves differently across Chrome versions.

Helpers in `tests/emulator/fixtures.js`:
- `swipe(page, selector, startX, startY, endX, endY, steps)` — single-finger swipe
- `pinch(page, selector, startDist, endDist, steps)` — two-finger pinch
- `sendCommand(page, cmd)` — type into IME input char-by-char

Verify gesture effects through app state, not visual diffs:
```javascript
// Scroll: check xterm buffer position
const vp = await page.evaluate(() => window.__testTerminal.buffer.active.viewportY);

// Swipe: check WS spy for tmux commands
const msgs = await page.evaluate(() => window.__mockWsSpy.filter(...));

// Pinch: check terminal font size
const font = await page.evaluate(() => window.__testTerminal.options.fontSize);
```

## Test Maturation Phases

Integration tests on real devices go through distinct phases. Tune verbosity and strictness to match the current phase.

**Phase 1: Bootstrapping (where MobiSSH is now)**
- Reporter: `['list', { printSteps: true }]` for maximum visibility
- `actionTimeout: 10_000` for fast failure on wrong selectors
- `retries: 0` so every failure is visible and investigated
- `screenshot: 'on'` for every test (attached to HTML report)
- Assertions should be tight and specific
- Every failure gets root-caused, not retried away

**Phase 2: Stabilization (after core workflows are reliable)**
- Keep verbose reporter but consider adding `retries: 1` for flaky infra
- Start grouping related assertions (e.g. one test for "connect and verify state" instead of separate connect/verify)
- Add `trace: 'retain-on-failure'` for post-mortem debugging

**Phase 3: Maintenance (stable test suite)**
- Switch to `['line']` reporter for compact output
- `retries: 2` for infrastructure flakiness (emulator hiccups, CDP drops)
- Loosen assertions that break on minor UI changes (check behavior not exact values)
- Guard against false positives: if a test hasn't failed in 20 runs, verify it can still detect regressions

Key principle: never skip Phase 1. The debugging cost of silent failures in integration tests is 10x higher than in unit tests.

## Templates and Scripts

Everything needed to add Android emulator testing to a new project is in the skill assets. Copy, adapt the marked variables, and run.

**Setup (one-time):**
- `scripts/setup-avd.sh` — Installs Android SDK, creates AVD, tunes config. Adapt `AVD_NAME`, `SYSTEM_IMAGE`, `DEVICE_PROFILE`.

**Test infrastructure:**
- `assets/run-emulator-tests-template.sh` — Full test runner: boots emulator, sets up CDP, starts screen recording, runs Playwright, collects baseline screenshots + video. Adapt `APP_PORT`, `APP_SERVER_CMD`, `AVD_NAME`.
- `assets/emulator-config-template.js` — Playwright config for CDP connection. Adapt `SERVER_PORT`, `SERVER_CMD`.
- `assets/emulator-fixtures-template.js` — Worker-scoped CDP browser, per-test tab with localStorage isolation + reload pattern.
- `assets/emulator-test-template.js` — Single test file with screenshot helpers and common patterns (vault setup, form interaction).

**Baseline results:**
The test runner collects results into `tests/emulator/baseline/` (tracked by git):
- `screenshots/` — per-test PNG screenshots with descriptive names
- `recording.mp4` — full screen recording of the test run
- `report.json` — Playwright JSON reporter output with per-test timing
- `frames/` — extracted video frames at test-critical moments (see below)

Add to `.gitignore`:
```
playwright-report/
playwright-report-emulator/
test-results/
!tests/emulator/baseline/
```

## Post-Run Video Frame Extraction

Playwright's failure screenshots only show the DOM state at timeout — after the problem has already manifested. The screen recording captures everything, but a 3-minute video is useless for debugging without timestamps.

`scripts/extract-test-frames.sh` bridges this gap: it reads the JSON test report, correlates each test's wall-clock timing with the video timeline, and extracts PNG frames at critical moments via ffmpeg. This gives the AI (or a human) a visual timeline of what was actually on screen when each test ran.

**How it works:**
1. Reads `tests/emulator/baseline/report.json` for test names, start times, durations, and pass/fail status
2. Calculates video offset: `test_startTime - earliest_startTime` maps wall-clock to video position
3. Extracts frames at: 2s before test start, midpoint, 1s before end
4. For failed tests: extracts additional quarter-point and three-quarter-point frames
5. Filenames encode the test name, moment, and status for easy scanning

**Usage:**
```bash
# After running emulator tests:
bash scripts/extract-test-frames.sh              # all tests
bash scripts/extract-test-frames.sh --failed      # only failed tests
bash scripts/extract-test-frames.sh --test "vault" # tests matching pattern
```

**Output example:**
```
tests/emulator/baseline/frames/
  smoke-page-loads-and-renders-MobiSSH-shell-0-before.png
  smoke-page-loads-and-renders-MobiSSH-shell-1-midpoint.png
  smoke-page-loads-and-renders-MobiSSH-shell-2-end-passed.png
  gestures-vertical-swipe-scrolls-terminal-0-before.png
  gestures-vertical-swipe-scrolls-terminal-1a-quarter.png    # failed: extra frames
  gestures-vertical-swipe-scrolls-terminal-1-midpoint.png
  gestures-vertical-swipe-scrolls-terminal-1b-threequarter.png
  gestures-vertical-swipe-scrolls-terminal-2-end-failed.png
```

**Why this matters for AI-assisted debugging:**
When the AI reviews a test failure, it can read the extracted frames to understand whether:
- The app was showing the expected dialog (host key, vault) or an unexpected interruption (Chrome "Save password?" bar, notification prompt)
- A button click failed because of a real layout bug vs. a Chrome-native overlay
- The test flow reached the right screen before timing out
- The emulator was responsive or frozen

This is the exit route from "guess why it failed from the error message" to "see what the user would have seen."

**Prerequisites:** `ffmpeg` and `jq` must be installed. The emulator Playwright config must include the JSON reporter (already configured):
```javascript
reporter: [
  ['list', { printSteps: true }],
  ['html', { open: 'never', outputFolder: 'playwright-report-emulator' }],
  ['json', { outputFile: 'tests/emulator/baseline/report.json' }],
],
```

## Testing Checklists

### Vault / Credential Testing
- [ ] First-run: master password modal appears on first profile save
- [ ] Password strength meter updates as you type
- [ ] Vault creation completes, modal dismisses, toast shows
- [ ] Chrome autofill does NOT interfere with vault password fields
- [ ] Profile save encrypts credentials (check via DevTools > Application > localStorage)
- [ ] Profile load decrypts and populates form fields
- [ ] Lock vault from settings, verify status changes to "Locked"
- [ ] Unlock via inline password bar
- [ ] Change master password, verify old password rejected after change
- [ ] Biometric enrollment (see fingerprint simulation below)

### Biometric / WebAuthn Testing
```bash
# Simulate fingerprint touch (finger ID 1) after WebAuthn prompt appears
adb emu finger touch 1
```
- [ ] "Enable fingerprint unlock" toggle appears during vault setup
- [ ] Fingerprint enrollment completes with simulated touch
- [ ] After lock, biometric prompt appears and fingerprint unlocks vault
- [ ] Disabling biometric in settings removes the biometric path

### PWA Install Testing
- [ ] Chrome shows "Add to Home Screen" in menu (or install banner)
- [ ] Installed PWA opens in standalone mode (no browser chrome)
- [ ] Service worker caches assets for offline fallback
- [ ] SW update prompts or applies transparently on next load

### Touch / IME Testing
- [x] Vertical swipe scrolls terminal scrollback (gestures.spec.js)
- [x] Horizontal swipe sends tmux prev/next window commands (gestures.spec.js)
- [x] Pinch-to-zoom changes terminal font size (gestures.spec.js)
- [ ] Virtual keyboard appears when tapping terminal or IME area
- [ ] Swipe typing produces correct characters
- [ ] Key bar buttons (Ctrl, Esc, Tab, arrows) send correct sequences
- [ ] No green overlay or unwanted selection on double-tap (selection overlay removed in 0ac4010)
- [ ] Ctrl sticky modifier works (tap Ctrl, then tap letter)

## Useful ADB Commands

```bash
adb devices                                        # list connected
adb shell getprop ro.build.version.release         # Android version
adb reverse tcp:8081 tcp:8081                      # port forwarding
adb forward tcp:9222 localabstract:chrome_devtools_remote  # CDP
curl -sf http://127.0.0.1:9222/json/version        # verify CDP
adb emu finger touch 1                             # simulate fingerprint
adb shell input text 'hello'                       # type text
adb exec-out screencap -p > /tmp/screenshot.png    # screenshot
adb logcat -s chromium                             # Chrome logs
adb shell am start -a android.intent.action.VIEW -d 'http://localhost:8081'
adb emu kill                                       # stop emulator
```

## Troubleshooting

**Emulator won't start / KVM error**: Add user to kvm group: `sudo usermod -aG kvm $USER`. Then `sg kvm -c 'emulator -avd MobiSSH_Pixel7'` or re-login.

**CDP not reachable after Chrome launch**: Run `adb shell am set-debug-app --persistent com.android.chrome`, force-stop Chrome, relaunch it, then re-forward: `adb forward tcp:9222 localabstract:chrome_devtools_remote`.

**Port forwarding not working**: `adb reverse --list` to verify. If empty, re-run `adb reverse tcp:8081 tcp:8081`.

**Tests fail with "Target page, context or browser has been closed"**: CDP connection is being recreated per test. Use worker-scoped `cdpBrowser` fixture (see fixtures.js).

**WebAuthn not prompting for fingerprint**: Chrome 120+ required. Emulator needs fingerprint enrolled in Settings > Security > Fingerprint (use `adb emu finger touch 1` during setup flow).

## When to Use This vs Playwright

| Scenario | Tool |
|---|---|
| Logic, state, DOM structure | Playwright |
| CSS layout on specific viewports | Playwright |
| Chrome autofill / password manager | Emulator |
| WebAuthn / biometric | Emulator |
| PWA install + standalone mode | Emulator |
| Real touch/swipe/IME | Emulator |
| Service worker update flow | Emulator |
| Visual regression on notched devices | Emulator |

Rule of thumb: if the feature involves browser-native UI that Playwright's headless Chromium doesn't have (password manager, biometric prompt, install banner), use the emulator.
