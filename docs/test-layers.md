# Test Coverage Matrix

Maps each behavior area to which test layer covers it, with confidence ratings.

## Layer Definitions

### Headless (Playwright, 3 emulated devices)

**Config:** `playwright.config.js`
**Devices:** Pixel 7, iPhone 14, Desktop Chrome (browser-emulated, not real hardware)
**Transport:** Playwright controls Chromium/WebKit via CDP; touch events are synthesized by the browser engine

**Can validate:**
- DOM structure, CSS class presence, panel visibility
- JavaScript state machine transitions via `page.evaluate()`
- WebSocket protocol messages via mock SSH server (`mockSshServer` fixture)
- Keyboard event routing via `page.keyboard` and `dispatchEvent()`
- localStorage read/write (vault encryption invariants, settings persistence)
- Service worker registration, cache versioning, manifest fields
- Synthetic composition events (IME state machine paths)
- ANSI/VT sequence pass-through to the mock server stream

**Cannot validate:**
- Real OS keyboard dismiss behavior (visualViewport changes)
- Actual GBoard swipe timing, candidate cycling, word disambiguation
- Real touch physics (momentum, friction, palm rejection)
- Canvas pixel rendering (xterm.js uses DOM renderer in headless, not canvas)
- Real biometric prompts or PasswordCredential UI
- Multi-touch gestures with hardware pressure data
- ADB input events

### Emulator (CDP + ADB)

**Config:** `playwright.emulator.config.js`
**Device:** Android emulator, real Chrome via CDP over ADB-forwarded port
**Transport:** Playwright CDP connection to real Chrome; ADB `input swipe` for gesture injection

**Can validate:**
- Real Chrome DOM APIs on Android (visualViewport, keyboard dismiss events)
- ADB-injected single-finger swipes via `adb shell input swipe`
- CDP `Input.dispatchTouchEvent` for multi-touch (pinch, two-finger swipe)
- Real canvas rendering (GPU-accelerated Chrome)
- Vault autofill interference (Chrome's password manager behavior)
- Real keyboard show/hide transitions and IME positioning

**Cannot validate:**
- Real GBoard composition events (emulator uses software keyboard, not GBoard)
- Real finger pressure/size data
- Multi-touch via `adb input` (single-finger only; CDP required)
- Screen recording of test interactions (handled externally by `adb screenrecord`)

### Appium (UiAutomator2)

**Config:** `playwright.appium.config.js`
**Device:** Android emulator, Chrome via WebDriverIO → Appium → UiAutomator2
**Transport:** Playwright is the test runner only; all device interaction via WebDriverIO W3C Actions API

**Can validate:**
- Real W3C multi-touch gesture sequences (pointer down/move/up with timing)
- Long-press detection (OS-level, not JS synthetic)
- Real drag-to-select via UiAutomator2 pointer actions
- Native Android dialogs (host key dialogs, permission prompts)
- Context switching between WebView and native contexts
- Screen recording via `adb screenrecord` (attached as test artifacts)
- Frozen regression baselines (pixel-stable behavior assertions)

**Cannot validate:**
- Non-visual JavaScript state (must use WebView context + JS evaluation)
- Real GBoard (emulator uses AOSP keyboard)
- Physical device sensors

## Coverage Matrix

| Behavior | Headless | Emulator | Appium | Confidence | Notes |
|---|---|---|---|---|---|
| IME composition (GBoard swipe, voice, candidate selection) | MEDIUM | LOW | NONE | LOW | Headless uses synthetic `CompositionEvent`; emulator uses AOSP soft keyboard; real GBoard only on physical device |
| IME state machine (idle/composing/previewing/editing transitions) | HIGH | MEDIUM | NONE | HIGH | `ime.spec.js` (38 tests) exercises all state transitions via synthetic events; emulator `input-mode.spec.js` (4 tests) validates cold boot and compose toggle |
| Gesture scroll (terminal scrollback, tmux, SGR mouse codes) | NONE | HIGH | HIGH | HIGH | Emulator `gestures.spec.js` (5) + `gesture-interaction.spec.js` (5) use CDP touch + ADB swipe; Appium `gesture-scroll-baseline.spec.js` (5, frozen) validates scroll direction with fill-scrollback.sh sections A–E |
| Selection (long-press, drag, multi-touch) | NONE | LOW | HIGH | HIGH | Appium `selection-longpress-baseline.spec.js` (5, frozen) + `selection-dragselect-baseline.spec.js` (9, frozen) + `selection-dragselect-explore.spec.js` (3); emulator `gesture-interaction.spec.js` covers CDP-injected gestures |
| Keyboard visibility (visualViewport, IME positioning) | LOW | MEDIUM | NONE | MEDIUM | Headless: no real keyboard events; emulator `input-mode.spec.js` validates visualViewport-based positioning on real Chrome |
| Vault (crypto, AES-GCM, PasswordCredential) | HIGH | MEDIUM | NONE | HIGH | `vault.spec.js` (8 tests) covers encrypt/decrypt, no-plaintext invariant, unlock flow; emulator `vault-regression.spec.js` (3 tests) validates Chrome autofill non-interference (#98) |
| Connection (WebSocket, reconnect, SSH handshake) | HIGH | MEDIUM | LOW | HIGH | `connection.spec.js` (11 tests) covers connect message, resize, disconnect, keepalive, hostkey; emulator `smoke.spec.js` (5) + Appium `smoke.spec.js` (5) validate real SSH on live sshd |
| Layout (tabs, panels, key bar, responsive breakpoints) | HIGH | NONE | MEDIUM | MEDIUM | `layout.spec.js` (32 tests) on 3 devices; `panels.spec.js` (5); `ui.spec.js` (20); Appium `integrate-145-settings-layout.spec.js` (3) validates settings layout on real device |
| Notifications (permission, background-only, bell badge) | HIGH | NONE | NONE | MEDIUM | `notifications.spec.js` (13 tests) covers bell/OSC9/OSC777 via mocked SW `showNotification`; no emulator or real-permission tests |
| PWA (install prompt, service worker, offline) | HIGH | NONE | NONE | MEDIUM | `pwa-install.spec.js` (9 tests): beforeinstallprompt, SW v3→v4 upgrade, cache purge, recovery overlay, manifest fields; Chromium-only for install prompt |
| Touch targets (44px minimum, pointer events) | MEDIUM | NONE | NONE | LOW | `layout.spec.js` checks element visibility; no explicit 44px assertion tests exist; Appium `user-workflow.spec.js` (8) exercises tappability indirectly |
| Terminal rendering (ANSI, truecolor, box-drawing, alternate buffer) | HIGH | MEDIUM | NONE | HIGH | `tui.spec.js` (29 tests) covers ANSI 256-color, truecolor, SGR, box-drawing, smcup/rmcup; emulator gestures confirm real canvas rendering |
| Session recording (asciicast v2, start/stop, auto-save) | HIGH | NONE | NONE | MEDIUM | `recording.spec.js` (6 tests) covers recording lifecycle, UI state, file download, auto-save on disconnect |
| Profiles (CRUD, upsert, private-key auth) | HIGH | NONE | LOW | HIGH | `profiles.spec.js` (6 tests) + `vault.spec.js` covers profile save/load; Appium `user-workflow.spec.js` covers form interaction |
| Settings (font size, theme, toggles) | HIGH | NONE | LOW | HIGH | `settings.spec.js` (6 tests) + `terminal.spec.js` (5 tests) verify localStorage persistence; Appium `integrate-145-settings-layout.spec.js` (3) validates layout |

## Test Counts

### Headless (`tests/*.spec.js`, `playwright.config.js`, 3 devices)

| File | Tests | Coverage area |
|---|---|---|
| `ime.spec.js` | 38 | IME state machine, key routing, ctrl combos, key bar |
| `tui.spec.js` | 29 | ANSI rendering, box-drawing, alternate buffer, function keys |
| `layout.spec.js` | 32 | Initial load, tab navigation, responsive layout on 3 devices |
| `ui.spec.js` | 20 | UI interactions, modals, error dialogs |
| `connection.spec.js` | 11 | WebSocket lifecycle, reconnect, keepalive, hostkey |
| `routing.spec.js` | 12 | URL routing, panel switching |
| `notifications.spec.js` | 13 | Bell, OSC 9/777, permission, background-only mode |
| `pwa-install.spec.js` | 9 | Install prompt, SW upgrade, cache, recovery overlay, manifest |
| `vault.spec.js` | 8 | AES-GCM encrypt/decrypt, no-plaintext invariant, unlock |
| `ui-screenshots.spec.js` | 8 | Visual regression screenshots |
| `production.spec.js` | 7 | Production server smoke tests |
| `profiles.spec.js` | 6 | Profile CRUD, upsert on host+port+username |
| `settings.spec.js` | 6 | Font size, theme, toggle persistence |
| `recording.spec.js` | 6 | Asciicast v2 recording lifecycle |
| `terminal.spec.js` | 5 | xterm.js init, font, theme, resize |
| `panels.spec.js` | 5 | Panel show/hide, tab bar visibility |
| `browserstack-smoke.spec.js` | 1 | BrowserStack smoke (skipped in local runs) |
| **Total** | **216** | |

Each headless test runs across Pixel 7, iPhone 14, and Desktop Chrome = 648 total test executions.

### Emulator (`tests/emulator/*.spec.js`, `playwright.emulator.config.js`)

| File | Tests | Coverage area |
|---|---|---|
| `gestures.spec.js` | 5 | Vertical scroll, horizontal swipe (tmux), pinch-to-zoom |
| `gesture-interaction.spec.js` | 5 | Gesture isolation, pairwise interference, direction-aware assertions |
| `input-mode.spec.js` | 4 | Direct mode default, compose toggle, auto-revert, real SSH input |
| `gesture-probe.spec.js` | 4 | Gesture diagnostic probe (development aid) |
| `smoke.spec.js` | 5 | Cold start, real SSH connection via Docker test-sshd |
| `explore-workflow.spec.js` | 3 | Exploratory workflow (non-frozen) |
| `vault-regression.spec.js` | 3 | Chrome autofill non-interference (#98), vault setup on real Chrome |
| `tmux-scroll.spec.js` | 3 | tmux scrollback via real SSH |
| `quick-probe.spec.js` | 1 | Quick diagnostic probe |
| **Total** | **33** | |

### Appium (`tests/appium/*.spec.js`, `playwright.appium.config.js`)

| File | Tests | Frozen | Coverage area |
|---|---|---|---|
| `selection-dragselect-baseline.spec.js` | 9 | Yes | Drag-to-select via W3C pointer actions |
| `user-workflow.spec.js` | 8 | No | Full end-to-end: vault, connect, SSH, gestures, all panels |
| `selection-longpress-baseline.spec.js` | 5 | Yes | Long-press chip: Paste, Select Visible, Select All, dismiss |
| `gesture-scroll-baseline.spec.js` | 5 | Yes | Vertical scroll direction (sections A–E from fill-scrollback.sh) |
| `smoke.spec.js` | 5 | No | Real SSH connection and terminal readiness |
| `gesture-multi-feature.spec.js` | 5 | No | Multi-feature gesture interaction |
| `selection-dragselect-explore.spec.js` | 3 | No | Exploratory drag-select |
| `integrate-117-wss-host-warning.spec.js` | 3 | No | WSS host warning dialog (#117) |
| `integrate-145-settings-layout.spec.js` | 3 | No | Settings panel layout on real device (#145) |
| `integrate-123-password-detection.spec.js` | 2 | No | Password detection regression (#123) |
| **Total** | **48** | | |

## Gaps — Behaviors With No Automated Coverage at Any Layer

The following behaviors have no automated test coverage at any layer:

1. **Real GBoard swipe composition** — `ime.spec.js` uses synthetic `CompositionEvent` sequences. The actual GBoard timing (compositionupdate rate, candidate list cycling, word disambiguation) is untested. Requires physical Android device with GBoard installed.

2. **Voice input** — No test covers the voice-to-text IME path. Requires physical device with voice recognition.

3. **iOS keyboard dismiss** — No emulator or Appium tests cover iOS Safari's keyboard dismiss and `visualViewport` behavior. Requires iOS Simulator or real device.

4. **Biometric unlock (PasswordCredential)** — `vault.spec.js` covers the AES-GCM crypto path. The Chrome Android biometric prompt triggered by `navigator.credentials.get()` is not automatable in any current layer.

5. **Pinch-to-zoom font scaling** — Emulator `gestures.spec.js` tests pinch direction; no test asserts font size change after pinch.

6. **Touch target size (44px minimum)** — No test explicitly measures button dimensions. Indirectly covered by Appium tap tests but no assertion on computed size.

7. **Offline PWA behavior** — `pwa-install.spec.js` tests SW cache installation but does not simulate network loss to verify the offline fallback page renders.

8. **Notification permission denied flow** — `notifications.spec.js` mocks `Notification.permission = 'granted'`. The denied/prompt → denied flow is untested.

9. **SSH private key authentication** — `profiles.spec.js` verifies key storage. No test performs a real SSH handshake with a private key.

10. **Multi-window / split-screen (Android)** — No test covers the PWA behavior when placed in Android split-screen or freeform window mode.

11. **Screen orientation change** — No test covers portrait-to-landscape rotation and layout reflow.
