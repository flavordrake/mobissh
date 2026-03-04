---
name: gesture-testing
description: Use when debugging touch/gesture issues on Android emulator, when a gesture feature is added or modified, when emulator tests pass but device testing fails, or when the user says "diagnose gestures", "debug touch", "gesture audit", "why aren't touches working", "scroll not working", "pinch broken", or "gesture interaction".
---

# Gesture Testing

Guide for developing and debugging touch gesture features in MobiSSH. The frozen baseline test suite is the ground truth — when a new feature breaks a baseline, the feature has a regression.

## Resources (same directory)

- **[case-studies.md](case-studies.md)** — historical bugs with root causes and fixes
- **[instrumentation-cookbook.md](instrumentation-cookbook.md)** — code recipes for touch tracing, viewport polling, handler registry

## Baseline Test Suite

| Test file | Tests | What it covers | Status |
|---|---|---|---|
| `gesture-scroll-baseline.spec.js` | 5 | Direction-aware scroll in tmux and plain shell | FROZEN |
| `gesture-multi-feature.spec.js` | 5 | Scroll + horizontal swipe + pinch interaction | Active |
| `user-workflow.spec.js` | 8 | End-to-end user workflows including gestures | Active |

**Frozen baselines must not be modified.** New features get new spec files. If a baseline fails after a code change, the change has a regression — fix the code, not the test. Semgrep and pre-commit hooks enforce this.

**Always run via `scripts/run-appium-tests.sh`.** Never bare `npx playwright test --config=playwright.appium.config.js`. The script handles recording, ANR dismissal, archival, and validation.

## Adding a New Gesture Feature

### 1. Handler inventory

Before writing code, audit existing touch handlers:

```bash
grep -n 'addEventListener.*touch\|addEventListener.*pointer' src/modules/*.ts
```

Build a table: Element | Event | Options | preventDefault? | stopPropagation? | Feature.

Include xterm.js library handlers — they register on `document` and are invisible to `src/` searches.

### 2. Feature gate

Every gesture that intercepts touches must be behind a localStorage toggle:

| Feature | localStorage Key | Default | Guard |
|---|---|---|---|
| Pinch-to-zoom | `enablePinchZoom` | enabled | `_pinchEnabled()` in touchstart |
| Vertical scroll | `naturalVerticalScroll` | enabled | direction only |
| Horizontal swipe | `naturalHorizontalScroll` | enabled | direction only |
| Debug overlay | `debugOverlay` | disabled | `_enabled` flag |

No gate = add one before writing the handler.

### 3. Write the test first

Create a new spec file alongside baselines. Import fixtures from `tests/appium/fixtures.js`. Follow the patterns in `gesture-multi-feature.spec.js`:
- W3C Actions with 15 intermediate pointerMove steps (40ms each)
- `performPinch()` helper for two-finger gestures
- `appiumSwipe()` for single-finger gestures
- WS spy for capturing tmux control sequences

### 4. Run baseline + new test

```bash
scripts/run-appium-tests.sh
```

The baseline must still pass. If it doesn't, the new code broke existing behavior.

### 5. Direction-aware assertions

Never assert only "content changed." Always assert direction.

`fill-scrollback.sh` generates sections A-E with directional markers:

| Gesture | Expected content | Wrong content |
|---|---|---|
| At bottom (initial) | Section E, "END OF DATA" | Sections A/B |
| Swipe to older | Sections A/B/C | Section E |
| Swipe to newer | Section D/E | Section A |

## Debugging a Gesture Failure

**Observe before changing.** One instrumented test run reveals the problem faster than multiple fix-compile-test cycles. See case-studies.md "guessing before observing."

### Classify the bug

| Category | Symptom | Approach |
|---|---|---|
| Test infra | Gesture never reaches the app | Check Appium context, native dialogs, element bounds |
| Handler conflict | Handler never runs or another swallows the event | Handler inventory, propagation audit |
| Wrong behavior | Handler runs but output is incorrect | Direction assertions, console log analysis |

### Propagation audit

```bash
grep -n 'preventDefault\|stopPropagation\|stopImmediatePropagation' src/modules/ime.ts
grep -n 'passive.*false\|capture.*true' src/modules/*.ts
```

Red flags:
- `preventDefault()` without a condition
- `stopPropagation()` in a touch handler
- `passive: false` on touchstart without clear reason
- `capture: true` + `preventDefault()` blocks everything downstream

### Instrument and observe

When static analysis doesn't reveal the issue, inject touch tracing into the failing test. See instrumentation-cookbook.md for recipes covering:
- Touch event tracing (which elements receive start/move/end)
- Viewport state polling (viewportY changes during gesture)
- Handler registry dump (all registered touch listeners including library code)
- Element chain instrumentation (DOM-level event delivery)

### Isolation test

If the bug involves gesture conflicts:
1. Disable ALL gesture features via localStorage
2. Enable ONE feature, test it
3. Enable pairwise combinations to find the conflict

## Appium Gesture Mechanics

Single-finger: `appiumSwipe(driver, startX, startY, endX, endY)` from fixtures.js.

Multi-finger (pinch): `performPinch(driver, ...)` — W3C Actions with two named pointers, switch to NATIVE_APP context before performing.

Long-press: `mobile: longClickGesture` UiAutomator2 command, or W3C Actions with extended pointerDown duration.

### Positioning

- Avoid screen edges (triggers Android navigation gestures)
- Avoid keyboard boundary crossings
- Natural thumb positions: X at left/right 1/4, Y start at ~2/3 down
- Slight diagonal drift (5-10%) is more realistic than perfectly vertical

## Debug Overlay

Settings > Danger Zone > Debug Overlay = ON

Console log patterns from gesture handlers:
- `[scroll] touchstart` — handler received event
- `[scroll] gesture claimed` — threshold crossed, preventDefault active
- `[scroll] delta=` — direction and magnitude
- `[scroll] SGR btn=` — mouse wheel button sent to tmux

Missing entries = event consumed by another handler first.
