---
name: gesture-diagnostics
description: Use when debugging touch/gesture issues on Android emulator, when a gesture feature is added or modified, when emulator tests pass but device testing fails, or when the user says "diagnose gestures", "debug touch", "gesture audit", "why aren't touches working", "scroll not working", "pinch broken", or "gesture interaction".
---

# Gesture Diagnostics

Systematic methodology for diagnosing touch and gesture issues in PWAs running on Android Chrome. Tool-agnostic: works with Appium (preferred), Playwright+CDP, or manual device testing.

## Resources (same directory)

- **[case-studies.md](case-studies.md)** — historical bug case studies with root causes and fixes
- **[instrumentation-cookbook.md](instrumentation-cookbook.md)** — copy-paste code for touch tracing, viewport polling, handler registry, element chain instrumentation
- **[probe-methodology.md](probe-methodology.md)** — progressive isolation via `gesture-probe.html` test page

## Architecture Note

ADB gesture testing is **retired**. Appium v2 + UiAutomator2 + WebDriverIO is operational with 5 baseline scroll tests passing. Run with `scripts/run-appium-tests.sh`. Key infrastructure:
- `tests/appium/fixtures.js` — session management, gesture helpers, SSH connection
- `tests/appium/gesture-scroll-baseline.spec.js` — 5 direction-aware scroll regression tests (**FROZEN**)
- `scripts/setup-appium.sh` — environment setup (run as normal user, NOT sudo)
- Screen recording via `adb emu screenrecord start/stop` (webm, validated by ffprobe)
- All scripts log to `/tmp/*.log` for post-run diagnosis

## Test Layering (READ BEFORE ADDING TESTS)

**Baseline tests (`*-baseline.spec.*`) are frozen.** They capture known-correct behavior and must not be modified. When adding gesture features:

1. Create a **new spec file** alongside the baseline (e.g. `gesture-horizontal.spec.js`)
2. Import the same fixtures from `fixtures.js` — add new helpers there if needed
3. The baseline tests run alongside new tests; if baselines fail, the feature broke existing behavior
4. Never weaken a baseline assertion to accommodate a new feature

Enforcement: semgrep `frozen-baseline-test` rule (ERROR), pre-commit hook blocks staged changes to baseline files. See CLAUDE.md "Test Layering Policy".

## Core Principles

**GROUND TRUTH, NOT GREEN TESTS.** The goal is for tests to exercise real, human-like behavior so you can fix the actual code until it works. Never downgrade test fidelity to get a passing score.

**Observe Before Changing.** NEVER change gesture code to "try a fix" without first instrumenting and observing. Gesture bugs have high fix-cycle cost (compile, restart, wait for test). A single instrumented observation run reveals the real problem faster than 5 rounds of guessing. See case-studies.md "guessing before observing" for the cost of violating this.

**Isolation Before Integration.** Every gesture feature must work in isolation before being tested alongside others.

**Native Environment Matters.** Chrome on Android wraps web content in native UI (URL bar, dialogs, password manager, permissions). Any test tool that only sees web content will eventually be defeated by a native dialog. Test infrastructure MUST be able to interact with the full device UI (this is what Appium provides).

## Phase 0: Instrument and Observe (MANDATORY before code changes)

When a gesture test fails, the FIRST action is to add instrumentation and observe. Do NOT hypothesize a fix.

**Circuit breaker:** If you've tried 2+ hypotheses without progress, go straight to element chain instrumentation (see instrumentation-cookbook.md). One run produces a complete picture.

Steps:
1. Inject touch event tracing (instrumentation-cookbook.md, "Touch Event Tracing")
2. Capture pre-gesture state (instrumentation-cookbook.md, "Pre-Gesture State Snapshot")
3. Run the gesture
4. Collect and analyze diagnostic data (instrumentation-cookbook.md, "Diagnostic Report Assembly")
5. Consult the symptom table (instrumentation-cookbook.md, "Interpreting Diagnostic Output")

## Phase 0.5: Progressive Isolation

When Phase 0 reveals touches aren't reaching the DOM at all, use the progressive isolation methodology to binary-search which layer breaks delivery. See probe-methodology.md for the full approach.

## Phase 1: Static Analysis (seconds, no emulator needed)

Run these before touching the emulator. They catch the most common LLM-introduced gesture bugs.

### 1a. Handler Inventory

```bash
grep -n 'addEventListener.*touch\|addEventListener.*pointer' src/modules/*.ts
```

Build a table: File:Line | Element | Event | Options | preventDefault? | stopPropagation? | Feature

Flag any element with 2+ listeners for the same event type.

**Include library source.** xterm.js registers handlers on `document` that are invisible to `src/` searches. Check node_modules/@xterm/xterm source too.

### 1b. Semgrep

```bash
semgrep --config .semgrep/rules.yml src/ --no-git-ignore --severity WARNING
```

### 1c. Propagation Audit

```bash
grep -n 'preventDefault\|stopPropagation\|stopImmediatePropagation' src/modules/ime.ts src/modules/ui.ts
grep -n 'passive.*false\|capture.*true' src/modules/*.ts
```

Red flags:
- `preventDefault()` without a condition
- `stopPropagation()` in a touch handler
- `passive: false` on touchstart without clear reason
- `capture: true` + `preventDefault()` = blocks everything downstream

### 1d. Feature Gate Audit

Every gesture feature that intercepts touches MUST be behind a localStorage toggle:

| Feature | localStorage Key | Default | Handler Guard |
|---------|-----------------|---------|---------------|
| Pinch-to-zoom | `enablePinchZoom` | `true` | `_pinchEnabled()` in touchstart |
| Debug overlay | `debugOverlay` | `false` | `_enabled` flag in console hook |
| IME mode | `imeMode` | `true` | `appState.imeMode` in keydown |

New gesture features must follow this pattern. No gate = add one before testing.

## Phase 2: Handler Isolation Tests (emulator, per-feature)

1. Disable ALL gesture features via localStorage
2. Enable ONE feature at a time
3. Test in isolation
4. Verify no interference from disabled features

### Isolation Test Pattern

```javascript
test('scroll works with pinch disabled', async ({ driver }) => {
  // GIVEN: pinch disabled, only scroll active
  await driver.executeScript('localStorage.setItem("enablePinchZoom", "false")', []);

  // WHEN: single-finger vertical swipe
  // (Appium: mobile:swipeGesture or W3C Actions)
  // (ADB: adb shell input swipe — retired)

  // THEN: verify DIRECTION, not just "content changed"
});
```

### Interaction Test Pattern

After isolation passes, test pairwise combinations:

| Feature A | Feature B | Test |
|-----------|-----------|------|
| Scroll (1-finger) | Pinch (2-finger) | Pinch then scroll, scroll then pinch |
| Scroll (1-finger) | Horizontal swipe | Diagonal swipe, near-threshold |
| Pinch (2-finger) | Horizontal swipe | Pinch release into swipe |

## Phase 3: Direction-Aware Assertions

**Never assert only that content changed. Always assert the direction of change.**

### Scrollback Markers

fill-scrollback.sh generates sections A-E (earliest to latest), each with 20 labeled lines:

| After This Gesture | Expected Content | Wrong Content (bug) |
|-------------------|-----------------|---------------------|
| At bottom (initial) | Section E, "END OF DATA" | Sections A/B |
| Swipe down (finger top→bottom, see older) | Sections A/B/C | Section E |
| Swipe up (finger bottom→top, see newer) | Section D/E | Section A |

### SGR Mouse Wheel Direction (tmux)

| Phone Gesture | SGR Button | Meaning |
|--------------|-----------|---------|
| Swipe up (bottom→top) | 65 (WheelDown) | Forward/newer |
| Swipe down (top→bottom) | 64 (WheelUp) | Back/older |

Mnemonic: phone swipe direction = content movement direction. Opposite of desktop scroll wheel.

```javascript
// GOOD: direction-aware
expect(afterSwipeDown).toMatch(/SECTION [AB]/);

// BAD: direction-agnostic
expect(afterSwipeDown).not.toBe(bottomContent);
```

## Phase 4: Multi-Touch (Appium W3C Actions)

Appium's W3C Actions API supports arbitrary multi-finger gestures. UiAutomator2 also provides high-level commands:

- `mobile: pinchOpenGesture` / `mobile: pinchCloseGesture` — zoom in/out
- `mobile: swipeGesture` — directional swipe with element targeting
- `mobile: longClickGesture` — long-press
- `driver.performActions([...])` — raw multi-pointer choreography

Element-relative targeting eliminates coordinate translation. No more `measureScreenOffset()`.

### Human-Like Gesture Positioning

- X: left or right 1/4 of screen (thumb rest), not dead center
- Y start: ~2/3 down (natural thumb reach)
- Slight diagonal drift (5-10% horizontal) is more natural than perfectly vertical
- Avoid screen edges (triggers Android navigation gestures)
- Avoid keyboard boundary crossings

### Pre-Flight Check

Before any gesture test, take a screenshot to confirm:
1. Chrome is fully visible (no native dialog blocking)
2. Terminal element is rendered
3. Keyboard state matches expectations
4. No Android system UI overlapping touch target

With Appium: switch to NATIVE_APP context, check for and dismiss any dialogs, switch back to WEBVIEW.

## Fastest-Failing Test Order

1. **Semgrep** (< 5s): Duplicate handlers, missing cleanup
2. **TypeScript typecheck** (< 10s): Type mismatches in handler params
3. **ESLint** (< 10s): Unused variables, unreachable code
4. **Headless Playwright** (< 60s): Handler registration, basic flow
5. **Emulator isolation tests** (< 3min): Per-feature touch behavior
6. **Emulator interaction tests** (< 5min): Cross-feature interactions
7. **Device validation** (manual): Real-finger with debug overlay

Stop at the first level that catches the bug.

## Debug Overlay for Device Testing

Settings > Danger Zone > Debug Overlay = ON

Key log patterns:
- `[scroll] touchstart` — handler received event
- `[scroll] gesture claimed` — threshold crossed, preventDefault active
- `[scroll] delta=` — direction and magnitude
- `[scroll] SGR btn=` — mouse wheel button sent to tmux
- `[scroll] flush` — batched events dispatched

Missing entries = event consumed by another handler first.
