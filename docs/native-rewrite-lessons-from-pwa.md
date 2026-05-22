# Native Rewrite (#501) — Features That Were Untenable on PWA

**Purpose.** Capture the features that consumed disproportionate engineering time on the PWA, and lock them into the Flutter rewrite's integration + acceptance test architecture from the beginning. The PWA's recurring failure mode was discovering platform-shaped bugs only on the user's phone, after headless tests passed. The rewrite must catch each of these classes of bug *before* they reach hardware.

Each feature below lists: what we tried on PWA, why it remained fragile (with code references), how the native architecture sidesteps the failure, and the test coverage that ships **starting in the named phase**, not as a polish step.

---

## 1. URL + file-path rich highlighting

### PWA reality
- `src/modules/pattern-links.ts`, `pattern-link-provider.ts`, `pattern-links-ui.ts` integrate xterm.js's link-provider API (#478).
- xterm.js renders to canvas — selection coordinates are buffer `(row, col)`, not DOM. Link-provider callbacks fire per-line, so soft-wrapped URLs require buffer-level reconstruction (`src/modules/ime-fixup.ts:reconstructFromBuffer`).
- User report (2026-05-21): URLs with indent continuations (e.g. wrapped Confluence links) not detected as continuous. The wrap-reconciliation in `ime-fixup.ts` exists for paste detection; the link provider doesn't currently consume it.
- File-path detection is context-sensitive (working dir, shell expansion, current user's home). Hard to do from canvas text alone.

### Native design (Phase 2)
- xterm.dart renders via Flutter widgets — per-cell `GestureDetector` is possible without canvas hit-testing.
- Single buffer-reconstruction layer (port the logic from `ime-fixup.ts`) feeds both selection-text-export and link-detection. **One source of wrap-aware text, not two.**
- Tap-to-open uses Flutter's explicit gesture arena to disambiguate from long-press (no race with selection).
- Persistent link decorations rendered as overlays on the terminal widget, not as text underlines (avoids xterm's awkward link decoration positioning).

### Test coverage that ships in Phase 2

| Tier | Test | Asserts |
|---|---|---|
| Unit | `test/buffer_reconstruction_test.dart` | wrap-aware text reconstruction for the same 20+ fixtures from PWA `ime-fixup.test.ts` (port them) — including: bare URLs, soft-wrapped URLs, URLs with `?query=foo&bar=baz`, paths with spaces, the Confluence indent-continuation case |
| Unit | `test/link_pattern_test.dart` | each pattern matcher against the reconstruction output — URL, IP, path, hostname, port number |
| Widget | `test/widget/link_tap_test.dart` | render terminal with known content, tap a matched link, assert intent fires |
| Widget | `test/widget/link_longpress_test.dart` | long-press on a matched link: selection wins, link tap does NOT fire (arena disambiguation) |
| Integration (Phase 6) | `integration_test/links_real_device.dart` | tap each link type on emulator, assert browser intent received |

---

## 2. Long-press to select → copy

### PWA reality
- Five fix cycles on `src/modules/selection.ts` (#502, latest fix `1de8ab7` on 2026-05-21).
- Three independent focus consumers fight for the hidden `.xterm-helper-textarea`:
  1. xterm.js (uses it for Cmd+C clipboard)
  2. Android Chrome IME (focuses any textarea → shows soft keyboard)
  3. Our IME state machine (`#imeInput` should hold focus for input)
- Android Chrome's synthetic mousedown → `xterm.rightClickHandler` → `helper.focus()` runs *before* any of our handlers can intervene (telemetry: `test-results/uploads/2026-05-21T20-49-55-gesture-telemetry`).
- `devloop/rules/know-when-to-quit.md`'s "selection-overlay" case study: 5 fix cycles before flagging off entirely.
- `tests/keyboard-stability-selection.spec.js` (headless) passes against current main but the bug *only* surfaces on real Android — because headless Chromium has no soft keyboard. The Appium tier was built after the fact, accumulating SW-cache / vault / module-cache state issues that ate hours.

### Native design (Phase 2)
- xterm.dart's selection is a first-class Flutter primitive (uses `SelectionContainer`).
- No hidden helper textarea. Clipboard via `flutter/services` `Clipboard.setData(...)`.
- Long-press via `LongPressGestureRecognizer` with explicit gesture arena membership — no IME interaction, no helper to fight for focus.
- Selection state owned by xterm.dart's `Terminal` model; we read/write via `terminal.userSelection`.

### Test coverage that ships in Phase 2

| Tier | Test | Asserts |
|---|---|---|
| Widget | `test/widget/selection_longpress_test.dart` | `tester.longPress(find.byType(TerminalView))` → selection model contains expected range |
| Widget | `test/widget/selection_drag_extend_test.dart` | long-press + drag → selection extends across multiple cells/rows |
| Widget | `test/widget/copy_button_test.dart` | tap Copy → `Clipboard.getData('text/plain')` returns wrap-aware text |
| Widget | `test/widget/selection_keyboard_stability_test.dart` | with mock soft-keyboard state (Flutter's `MediaQuery.viewInsets`), long-press → keyboard inset unchanged before and after |
| Integration (Phase 6) | `integration_test/selection_real_device.dart` | real Android long-press with keyboard up → keyboard stays up, selection captured, copy ends up in real clipboard. This is the test the PWA *needed* and never had until #502 was already five cycles deep. |

**Lock-in rule:** Phase 2's PR rejects if any selection-related widget test is missing. No selection ships without these in CI.

---

## 3. Reconnect / connection maintenance — quick resume across 5+ sessions

### PWA reality
- `src/modules/connection.ts` is ~1900 lines, of which roughly 1500 are reconnect/state-machine plumbing.
- Issues fought across the lifetime of the project: #29 (keepalive), #43 (wake lock), #153 (visibility reconnect), #194 (background reconnect), #498 (host-unreachable backoff), #497 (failed-state banner), the "soft_disconnected" state that exists *only* to disambiguate user-disconnect from network-drop.
- 5+ sessions cascade: visibility resume tries to reconnect all simultaneously; same Tailscale route flakes hit all of them; the user sees the session bar flash a wall of red-then-yellow-then-green dots.
- Browser tab suspension on background eats every WS. The keepalive-notification (`src/modules/keepalive-notification.ts`, 157 LOC) exists because the service worker can't hold connections — only the foreground tab can.
- The PWA's correct-behavior baseline is "reconnect quickly" because *staying connected is impossible*. The native architecture inverts that: stay connected, no reconnect needed.

### Native design (Phase 4)
- `flutter_foreground_task` keeps each SSH session alive in its own isolate, OS-anchored to a notification.
- App `onPause` / `onResume`: no reconnect. The UI rebinds to existing live `SSHClient` instances. The session is held by the foreground service, not the UI.
- Reconnect only on actual TCP loss (Tailscale flake, target host sleeping, hard network change). When it happens: per-session exponential backoff, no global cascade.
- 5+ sessions = 5+ `SSHClient` instances in the service. Each independent. Wake lock keeps them alive during doze.

### Test coverage that ships in Phase 4

| Tier | Test | Asserts |
|---|---|---|
| Unit | `test/session_lifecycle_test.dart` | state-machine transitions for: clean connect → disconnect, clean connect → network drop → reconnect, host-unreachable → backoff, user-disconnect |
| Widget | `test/widget/multi_session_rebind_test.dart` | open 5 sessions (mocked SSHClient), trigger `WidgetsBinding.instance.handleAppLifecycleStateChanged(paused)`, then `.resumed`. Assert all 5 still report `connected`, UI re-renders correctly. **Must complete bind <500ms.** |
| Widget | `test/widget/foreground_service_state_test.dart` | mock `flutter_foreground_task` lifecycle, assert session-state isolate survives a UI-only restart |
| Integration | `integration_test/connection_audit_test.dart` | run `Connection Audit` debug screen (see below) and assert per-session metrics: bytes since boot, last keepalive RTT, reconnect count |
| Real device (Phase 6) | manual — screen-off 10 min with 5 sessions, screen-on, assert all reconnect-free |

**Ship from Phase 4: Connection Audit debug screen.** A panel showing per-session: state, bytes in/out since session start, last keepalive RTT, reconnect count, time-since-last-reconnect. The PWA never had this — the only diagnostic was `connect-log.ts` localStorage + manual upload. The native app's audit screen is the production-visible counterpart of the redesign-doc telemetry layer; if quick-resume regresses, the audit reveals it before the user does.

**Performance budget for "quick resume":** UI rebind to terminal cells, scroll position, and selection state must complete within **500ms** of `AppLifecycleState.resumed`. The widget test enforces this — Phase 4 PR rejects if exceeded.

---

## 4. Adjacent features worth designing tests for from day 1

### IME / soft-keyboard input — Phase 2
- `src/modules/ime.ts` is 1556 LOC, four-state machine (idle/composing/previewing/editing) compensating for GBoard swipe-type, voice input, autocorrect, the lack of a real password mode.
- Most of it disappears under Flutter's native `TextField(obscureText: true)` + per-keyboard handling via `TextInputType`.
- **Tests (Phase 2):** widget tests for password-obscure, autocorrect=off, voice-dictation accuracy round-trip, swipe-typing accumulator behavior.

### Credential vault — Phase 3
- `src/modules/vault.ts` + `vault-ui.ts` ≈ 865 LOC: PBKDF2-600k + AES-GCM + PasswordCredential + WebAuthn-PRF dance, because the browser has no proper keystore.
- Native: `flutter_secure_storage` (OS Keychain/Keystore) + `local_auth` (biometric prompt) collapses to ~50 LOC equivalent.
- **Tests (Phase 3):** encrypt/store/retrieve round-trip, biometric prompt mocked via `local_auth`'s `MethodChannel` stub, lock/unlock cycle, key rotation. Real-device biometric test in Phase 6.

### Pinch-zoom semantics — Phase 2
- PWA fights `touch-action` semantics with Android Chrome's built-in page zoom (`src/modules/ui.ts:~2436-2549`, 115 LOC for the video pinch handler alone).
- Native: `GestureDetector.onScaleStart/Update/End` owns the gesture cleanly — no browser to compete with.
- **Tests (Phase 2):** widget gesture tests for pinch scale on `TerminalView`, assert font-size delta computed correctly. Real-device check in Phase 6.

### Port forwarding — Phase 5
- Impossible in browser sandbox. Termux helper attempt (#499) was reverted.
- Native: `SSHClient.forwardLocal(...)` from dartssh2 is a one-line API; the work is the UI (forwards panel) and the wiring.
- **Tests (Phase 5):** integration with `test-sshd` serving a small HTTP service through `-L`; assert HTTP fetch through the forwarded port returns expected response.

---

## Cross-cutting: test architecture principles

Every feature above must land with these tiers, in this priority order:

1. **Unit test** (Phase 1+) — model / state logic, no UI or network.
2. **Widget test** (Phase 2+) — user-facing flow, mocked SSH/storage. Uses Flutter's `pumpWidget` + `tester` infrastructure.
3. **Integration test** (Phase 4+) — runs against `test-sshd` Docker container on the `mobissh` network. Same fixture pattern as the PWA's `tests/integration/`.
4. **Real-device acceptance** (Phase 6) — Appium-via-flutter-driver OR Flutter's `integration_test` package on emulator. For IME / keyboard / gesture flows that headless can't reach.

### The cardinal rule

**No PR for a feature ships without the tier appropriate to that feature's failure modes.**

- Phase 1 (SSH lifecycle) PR: unit + widget required. Integration test passing against `test-sshd` is the merge gate.
- Phase 2 (xterm.dart) PR: must include widget tests for selection, link tap/long-press disambiguation, pinch, keyboard interaction. Real-device acceptance test stub committed (filled in Phase 6).
- Phase 3 (vault) PR: unit + widget required. Biometric flow mock + smoke test.
- Phase 4 (foreground service) PR: must include the multi-session rebind widget test AND the 500ms-budget enforcement.
- Phase 5 (port forwarding) PR: integration test against `test-sshd` is the merge gate.
- Phase 6 (polish) PR: real-device acceptance suite executes the stubs from earlier phases.

### The anti-pattern this rule prevents

The PWA shipped headless Playwright tests that passed for a year while the user encountered the same selection/IME bugs repeatedly on their device. Each headless test asserted the JS contract, none of them exercised the OS-soft-keyboard interaction that was the actual bug surface. The rewrite must NOT defer real-device coverage to Phase 6 for features whose failure modes are *only* real-device-visible. Selection (Phase 2) and reconnect (Phase 4) are the two examples; each requires its real-device test stub at the time of the phase's PR, even if the stub is just `// TODO Phase 6: enable when emulator is available`.

---

## Map: phase → coverage commitment

| Phase | Feature | Test commitment |
|---|---|---|
| 1 — SSH lifecycle | connect, auth, host-key | unit (state machine), widget (host-key dialog), integration (test-sshd banner round-trip) |
| 2 — xterm.dart | terminal render, **selection**, **links**, IME input | widget (per above), keyboard-stability widget with `MediaQuery.viewInsets` mock, real-device test stubs |
| 3 — vault + profiles | credentials | unit (crypto round-trip), widget (biometric prompt mock), real-device test stub |
| 4 — foreground service | **multi-session resume**, reconnect | unit (state), widget (rebind <500ms enforced), integration (foreground-task lifecycle), Connection Audit debug screen shipped |
| 5 — port forwarding | `-L` UI + transport | integration (test-sshd HTTP-through-forward), widget (Forwards panel) |
| 6 — polish | activates all real-device stubs | full Appium / flutter_driver acceptance suite |

If any phase's PR omits its tests, reject the PR. The PWA's 10 hours of #502 debugging today is the operational cost of relaxing that rule.
