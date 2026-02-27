---
name: gesture-diagnostics
description: Use when debugging touch/gesture issues on Android emulator, when a gesture feature is added or modified, when emulator tests pass but device testing fails, or when the user says "diagnose gestures", "debug touch", "gesture audit", "why aren't touches working", "scroll not working", "pinch broken", or "gesture interaction".
---

# Gesture Diagnostics

Systematic methodology for diagnosing touch and gesture issues in PWAs running on Android Chrome via emulator. This skill exists because gesture bugs are the hardest class of PWA bug to catch: they pass synthetic tests, fail on real devices, and resist debugging because mobile Chrome has no DevTools.

## When to Use

- A gesture feature was added or modified
- Emulator tests pass but the user reports broken behavior on device
- Touch events seem to be swallowed, misdirected, or duplicated
- A new `addEventListener('touch*')` or `addEventListener('pointer*')` is added
- Multiple gesture features coexist on the same element (scroll + pinch + swipe)
- Any `passive: false` or `capture: true` listener is added or changed

## Core Principle: Isolation Before Integration

Every gesture feature must work in isolation before being tested alongside others. When multiple handlers share an element, interaction bugs are invisible until you test the exact combination that triggers them. The diagnostic process starts with the fastest, cheapest checks and escalates only when needed.

## Phase 1: Static Analysis (seconds, no emulator needed)

Run these before touching the emulator. They catch the most common LLM-introduced gesture bugs.

### 1a. Handler Inventory

```bash
# Find ALL touch/pointer/gesture event listeners
grep -n 'addEventListener.*touch\|addEventListener.*pointer\|addEventListener.*click\|addEventListener.*gesture' src/modules/*.ts
```

Build a table:

| File:Line | Element | Event | Options | preventDefault? | stopPropagation? | Feature |

Flag any element with 2+ listeners for the same event type. These are the interaction hotspots.

### 1b. Semgrep Duplicate Detection

```bash
semgrep --config .semgrep/rules.yml src/ --no-git-ignore --severity WARNING
```

The `duplicate-event-listener` rule catches identical `addEventListener` calls on the same element. Intentional duplicates must have `// nosemgrep: duplicate-event-listener` with an explanation.

### 1c. Propagation Audit

Search for anything that could silently consume touch events:

```bash
# preventDefault in touch handlers — each one must be justified
grep -n 'preventDefault' src/modules/ime.ts src/modules/ui.ts

# stopPropagation — can silently kill sibling handlers
grep -n 'stopPropagation\|stopImmediatePropagation' src/modules/*.ts

# passive: false — tells browser "I might preventDefault", forces sync dispatch
grep -n 'passive.*false' src/modules/*.ts

# capture: true — runs before bubble phase, can intercept before target sees it
grep -n 'capture.*true' src/modules/*.ts
```

**Red flags:**
- `preventDefault()` without a condition (always blocks)
- `stopPropagation()` in a touch handler (kills siblings)
- `passive: false` on a touchstart without a clear reason (degrades scroll performance)
- `capture: true` + `preventDefault()` = gesture claim that blocks everything downstream

### 1d. Feature Gate Audit

Every gesture feature that could interfere with another MUST be behind a localStorage toggle:

```bash
grep -n 'localStorage.*getItem\|localStorage.*setItem' src/modules/ime.ts src/modules/settings.ts
```

Check that each touch-intercepting feature has:
1. A localStorage key (e.g., `enablePinchZoom`)
2. A settings UI toggle
3. Default = disabled (opt-in, not opt-out)
4. Guard at the top of its handler (return early when disabled)

**Current feature gates:**

| Feature | localStorage Key | Default | Handler Guard |
|---------|-----------------|---------|---------------|
| Pinch-to-zoom | `enablePinchZoom` | `false` | `_pinchEnabled()` in touchstart |
| Debug overlay | `debugOverlay` | `false` | `_enabled` flag in console hook |
| IME mode | `imeMode` | `true` | `appState.imeMode` in keydown |

Any NEW gesture feature must follow this pattern. If it doesn't have a gate, add one before testing.

## Phase 2: Unit-Level Gesture Tests (seconds, headless)

Before spinning up an emulator, run headless Playwright tests that verify gesture handler wiring. These can't test real touch physics but catch handler registration and basic event flow.

```bash
npx playwright test --config=playwright.config.js --grep "gesture\|scroll\|swipe\|pinch"
```

These tests use Playwright's native touch simulation. They're fast but limited: single-finger only, no multi-touch, no real Android input pipeline.

## Phase 3: Handler Isolation Tests (emulator, per-feature)

This is where real diagnosis happens. The methodology:

1. **Disable ALL gesture features** via localStorage
2. **Enable ONE feature** at a time
3. **Test that feature in isolation** with CDP touch events
4. **Verify no interference** from disabled features

### Setup: Baseline with All Gestures Disabled

```javascript
// In test setup, after page load:
await page.evaluate(() => {
  localStorage.setItem('enablePinchZoom', 'false');
  // Add future gesture toggles here as features are added
});
await page.reload({ waitUntil: 'domcontentloaded' });
```

### Isolation Test Pattern

```javascript
test('scroll works with pinch disabled', async ({ emulatorPage: page }) => {
  // GIVEN: pinch disabled (default), only scroll active
  await page.evaluate(() => {
    localStorage.setItem('enablePinchZoom', 'false');
  });

  // WHEN: single-finger vertical swipe via CDP
  await swipe(page, '#terminal', 200, 100, 200, 500, 20);

  // THEN: verify DIRECTION, not just "content changed"
  // After swipe-down (finger top→bottom), should see EARLIER content
});

test('pinch works with scroll active', async ({ emulatorPage: page }) => {
  // GIVEN: pinch enabled
  await page.evaluate(() => {
    localStorage.setItem('enablePinchZoom', 'true');
  });
  await page.reload({ waitUntil: 'domcontentloaded' });

  // WHEN: 2-finger pinch-out via CDP
  await pinch(page, '#terminal', 50, 200, 12);

  // THEN: font size increased
  const fontSize = await page.evaluate(() =>
    window.__testTerminal?.options.fontSize
  );
  expect(fontSize).toBeGreaterThan(14);
});
```

### Interaction Test Pattern

After isolation passes, test combinations:

```javascript
test('scroll still works after pinch gesture', async ({ emulatorPage: page }) => {
  // GIVEN: pinch enabled + scrollback content
  await page.evaluate(() => {
    localStorage.setItem('enablePinchZoom', 'true');
  });

  // WHEN: pinch, then scroll
  await pinch(page, '#terminal', 50, 200, 12);
  await page.waitForTimeout(300);

  const contentBefore = await readScreen(page);
  await swipe(page, '#terminal', 200, 100, 200, 500, 20);
  await page.waitForTimeout(500);
  const contentAfter = await readScreen(page);

  // THEN: scroll direction correct, content from earlier sections visible
  expect(contentAfter).not.toBe(contentBefore);
  // Direction-aware: swipe-down should show earlier content (sections A/B)
  expect(contentAfter).toMatch(/SECTION [AB]/);
});
```

## Phase 4: Direction-Aware Assertions

**This is the #1 lesson from production debugging.** Never assert only that content changed. Always assert the direction of change.

### The fill-scrollback.sh Markers

The test content generator creates labeled sections: A, B, C, D, E (earliest to latest), each with 20 numbered lines. Use these as directional anchors:

| After This Gesture | Expected Visible Content | Wrong Content (bug indicator) |
|-------------------|-------------------------|-------------------------------|
| At bottom (initial) | Section E, "END OF DATA" | Sections A/B |
| Swipe down (finger top→bottom, see older) | Sections A/B/C | Section E / "END OF DATA" |
| Swipe up (finger bottom→top, see newer) | Section D/E | Section A |

### SGR Mouse Wheel Direction (tmux)

In tmux with mouse mode enabled, scroll sends SGR mouse wheel escape sequences:

| Phone Gesture | Expected SGR Button | Meaning |
|--------------|-------------------|---------|
| Swipe up (finger bottom→top) | 65 (WheelDown) | Forward/newer content |
| Swipe down (finger top→bottom) | 64 (WheelUp) | Back/older content |

**Mnemonic:** Phone swipe direction = content movement direction. Swipe up → content moves up → see newer → WheelDown (65). This is the opposite of desktop scroll wheel convention.

### Assertion Examples

```javascript
// GOOD: direction-aware
expect(afterSwipeDown).toMatch(/SECTION [AB]/);
expect(afterSwipeDown).not.toMatch(/END OF DATA/);

// BAD: direction-agnostic (passes with inverted scroll)
expect(afterSwipeDown).not.toBe(bottomContent);
```

For SGR events:
```javascript
// GOOD: verify correct button code
const sgrButtons = sgrEvents.map(e => {
  const match = e.data.match(/\x1b\[<(\d+);/);
  return match ? parseInt(match[1]) : null;
});
// Swipe down (top→bottom) = WheelUp = button 64
expect(sgrButtons).toContain(64);
expect(sgrButtons).not.toContain(65);

// BAD: just check SGR events were sent
expect(sgrEvents.length).toBeGreaterThan(0);
```

## Phase 5: Multi-Touch Interaction Matrix

When the codebase has N gesture features on the same element, test the N*(N-1)/2 pairwise interactions. Currently:

| Feature A | Feature B | Test |
|-----------|-----------|------|
| Scroll (1-finger) | Pinch (2-finger) | Pinch then scroll, scroll then pinch |
| Scroll (1-finger) | Horizontal swipe (1-finger) | Diagonal swipe, near-threshold swipe |
| Pinch (2-finger) | Horizontal swipe (1-finger) | Pinch release into swipe |

### The ADB vs CDP vs Real Finger Spectrum

Understanding why synthetic tests miss real-world bugs:

| Input Method | Touch Count | Precision | Chrome Pipeline | Catches |
|-------------|-------------|-----------|----------------|---------|
| `adb shell input swipe` | Always 1 | Perfect | Full DOM events | Basic handler wiring |
| CDP `Input.dispatchTouchEvent` | 1 or 2 | Sub-pixel | Full DOM events | Multi-touch interactions, preventDefault |
| Real finger on device | Variable, imprecise | Fat-finger | Full DOM events + OS gestures | Palm rejection, edge touches, OS gesture conflicts |

**Key insight:** `adb shell input swipe` creates surgically clean single-finger events. It will NEVER trigger a 2-finger handler, even if the 2-finger handler has bugs. CDP `pinch()` helper is the minimum required to test multi-touch. Real device testing catches imprecise contact (brief 2-finger during intended 1-finger scroll).

## Fastest-Failing Test Order

Run tests in this order. Each level is faster and catches coarser bugs:

1. **Semgrep** (< 5s): Duplicate handlers, missing cleanup, magic escape sequences
2. **TypeScript typecheck** (< 10s): Type mismatches in event handler parameters
3. **ESLint** (< 10s): Unused variables from partial refactors, unreachable code
4. **Headless Playwright** (< 60s): Handler registration, basic event flow, WS message format
5. **Emulator isolation tests** (< 3min): Per-feature touch behavior with CDP
6. **Emulator interaction tests** (< 5min): Cross-feature touch interactions
7. **Device validation** (manual): Real-finger testing with debug overlay enabled

Stop at the first level that catches the bug. Don't burn 5 minutes on emulator tests when semgrep catches the duplicate handler in 3 seconds.

## Debug Overlay for Device Testing

When testing on a real device without DevTools, enable the debug overlay:

1. Settings > Danger Zone > Debug Overlay = ON
2. The overlay captures `console.log` and `console.warn` output
3. Touch events are logged with coordinates, touch count, and handler decisions
4. Copy button extracts the full log to clipboard for analysis

Key log patterns to look for:
- `[scroll] touchstart` — scroll handler received the event
- `[scroll] gesture claimed` — scroll threshold crossed, preventDefault active
- `[scroll] delta=` — scroll direction and magnitude
- `[scroll] SGR btn=` — which mouse wheel button was sent to tmux
- `[scroll] flush` — batched scroll events dispatched

Missing log entries indicate the event was consumed by another handler before reaching the scroll handler.

## Encoded Lessons

### Bug categories (do not conflate)

**Category 1: Gesture doesn't fire at all.** The handler never runs, or another handler swallows the event. This is the blocking bug. Causes: duplicate handlers fighting for the same event, unguarded `preventDefault()` in a sibling handler, `passive: false` causing Chrome to wait on a handler that interferes, feature code that was never gated and intercepts touches unconditionally.

**Category 2: Gesture fires but does the wrong thing.** The handler runs, but the output is incorrect (wrong direction, wrong magnitude, wrong target). This is a logic/semantic bug. Causes: inverted button codes, swapped coordinates, wrong threshold.

Category 1 makes the feature non-functional. Category 2 makes it incorrect. They require completely different diagnostic approaches. Static analysis and handler audits catch Category 1. Direction-aware assertions catch Category 2. Never assume a Category 2 fix (like swapping button codes) will resolve a Category 1 problem (gestures not firing).

### From scroll being completely blocked by pinch handlers
- The pinch-to-zoom handlers were registered unconditionally on the terminal element with `passive: false`. Even though the pinch handler returned early for 1-finger touches (`if (e.touches.length !== 2) return`), the mere registration of `passive: false` handlers changes Chrome's touch event dispatch behavior. Chrome cannot optimize the touch event pipeline when any non-passive handler exists on the element.
- The fix was not to change the pinch handler's logic — it was to gate the entire feature behind a localStorage toggle (`enablePinchZoom`), with default=disabled, so the handlers are never registered unless the user opts in.
- **The emulator tests passed because `adb shell input swipe` creates perfectly clean single-touch events.** The interference that blocked scroll on a real phone (where finger contacts are imprecise, where Chrome's handler scheduling matters, where `passive: false` has real performance consequences) simply doesn't occur with synthetic ADB input.
- Lesson: if a feature intercepts touch events, it MUST be feature-gated from day one. Do not register non-passive touch handlers unconditionally.

### From scroll direction bug (btn 64↔65)
- This was a separate, secondary issue discovered AFTER scroll was unblocked. SGR button semantics are counterintuitive on phones. Phone-native convention (swipe up = newer) is the opposite of desktop scroll wheel (wheel up = older).
- Test assertions that only check "content changed" will pass regardless of direction.
- Always include directional markers in test content and verify the direction explicitly.

### From duplicate handler discovery
- LLMs commonly add new handlers without removing or modifying old ones. Semgrep's `duplicate-event-listener` rule is the fastest catch.
- When `nosemgrep` is used, the comment MUST explain why the duplicate is intentional (e.g., "scroll uses 1-finger, pinch uses 2-finger").

### From the emulator test gap
- Emulator tests with `adb shell input swipe` produce clean synthetic events that don't reproduce real-world touch interference.
- CDP `Input.dispatchTouchEvent` is closer to reality (supports multi-touch) but still perfectly timed.
- The debugging hierarchy: static analysis catches structural bugs (Category 1), emulator catches logic bugs (Category 2), device catches physics/interference bugs (Category 1 in the wild).
- A passing emulator test does NOT mean the feature works on a real device if there are unguarded non-passive handlers on the same element.
