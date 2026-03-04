# Gesture Testing: Case Studies

Historical case studies from debugging gesture issues in MobiSSH.

## Bug Categories

**Category 0: Test infrastructure.** The app is correct, but the test delivers touches to the wrong target, a native dialog intercepts them, or the injection method doesn't reach the app.

**Category 1: Gesture doesn't fire.** The handler never runs, or another handler swallows the event. Causes: duplicate handlers, unguarded `preventDefault()`, `passive: false` changing Chrome dispatch, unconditional feature code intercepting touches.

**Category 2: Wrong behavior.** The handler runs but output is incorrect. Causes: inverted button codes, swapped coordinates, wrong threshold.

These require completely different approaches. Category 0 wastes time debugging the wrong layer.

## Pinch handlers blocking scroll (Category 1)

Pinch-to-zoom handlers were registered unconditionally on `#terminal` with `passive: false`. Even though the handler returned early for 1-finger touches, the registration itself changed Chrome's touch event dispatch behavior. Chrome cannot optimize the pipeline when any non-passive handler exists on the element.

**Fix:** Gate the entire feature behind `localStorage.enablePinchZoom` so handlers can be explicitly disabled.

**Lesson:** If a feature intercepts touch events, it MUST be feature-gated from day one. Do not register non-passive touch handlers unconditionally.

## Scroll direction, SGR btn 64/65 (Category 2)

SGR button semantics are counterintuitive on phones: phone-native convention (swipe up = newer) is the opposite of desktop scroll wheel (wheel up = older).

**Fix:** Direction-aware assertions using labeled scrollback content. Never assert only "content changed."

**Lesson:** Test assertions that only check "content changed" will pass regardless of direction. The baseline suite enforces directional correctness.

## xterm.js built-in touch scroll overriding our handler (Category 1)

xterm.js v6 registers `touchstart`/`touchmove`/`touchend` on `document` (bubble phase, passive:false). Our handler runs in capture phase on `#terminal`. Both process the same events; last `scrollLines()` call wins. Since xterm's runs after ours (bubble after capture), xterm always overrides our scroll direction.

**Symptom:** Direction fix in our handler has zero effect on viewportY.

**Fix:** `e.stopPropagation()` in our capture-phase handler after claiming the gesture, combined with `e.preventDefault()`.

**Lesson:** Handler inventory must include library source, not just `src/`. `grep -c 'touchstart\|touchmove' node_modules/@xterm/xterm/lib/xterm.js` reveals xterm's handlers.

## Native Chrome dialog blocking events (Category 0)

A Google Password Manager dialog covered the entire Chrome screen, silently intercepting all touch events. Playwright/CDP cannot see or interact with native Android UI.

**Root cause of ADB gesture testing retirement.** Each ADB infrastructure fix exposed the next failure mode. The final blocker was native dialogs that no web-only tool can handle.

**Lesson:** Mobile testing must interact with the full device UI. This is what Appium solves — it can switch to NATIVE_APP context, detect dialogs, and dismiss them.

## Guessing before observing (process failure)

5 consecutive test cycles spent trying fixes (direction inversion, selective stopPropagation, aggressive stopPropagation on all handlers). Each cycle: compile + restart + 3-minute test run. The aggressive stopPropagation attempt caused a regression by breaking pinch-to-zoom.

A single instrumented observation run immediately showed: zero touchmove events, negative coordinates, keyboard not dismissed.

**Lesson:** One observation run costs the same as one fix attempt but narrows the search space from "anything" to "here is exactly what happened." Always instrument first.

## Duplicate handler registration (Category 1)

Adding new handlers without removing old ones. Semgrep `duplicate-event-listener` rule catches this instantly. When `nosemgrep` is used, the comment must explain why the duplicate is intentional.

## Stale server serving old JS (Category 0)

TypeScript compilation writes to `public/modules/*.js`. The server caches git hash at startup. Compiling without restarting means the server reports "healthy at HEAD" while serving old code.

**Fix:** Restart the server after TypeScript changes. Verify with the version hash in Settings.
