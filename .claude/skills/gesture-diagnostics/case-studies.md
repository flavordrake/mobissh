# Gesture Diagnostics: Case Studies

Historical case studies from debugging gesture issues in MobiSSH. Referenced by SKILL.md.

## Bug Categories (do not conflate)

**Category 0: Test infrastructure delivers touches to wrong target.** The app is correct, but the test sends gestures to wrong coordinates, a native dialog intercepts them, or the injection method doesn't reach the app. Phase 0 instrumentation is the only way to catch this efficiently.

**Category 1: Gesture doesn't fire at all.** The handler never runs, or another handler swallows the event. Causes: duplicate handlers, unguarded `preventDefault()`, `passive: false` registration changing Chrome dispatch, unconditional feature code intercepting touches.

**Category 2: Gesture fires but does the wrong thing.** The handler runs but output is incorrect (wrong direction, magnitude, target). Causes: inverted button codes, swapped coordinates, wrong threshold.

Category 0 wastes debugging time on the wrong layer. Category 1 makes the feature non-functional. Category 2 makes it incorrect. They require completely different diagnostic approaches.

## Case: Pinch handlers blocking scroll (Category 1)

Pinch-to-zoom handlers were registered unconditionally on `#terminal` with `passive: false`. Even though the handler returned early for 1-finger touches (`if (e.touches.length !== 2) return`), the registration itself changed Chrome's touch event dispatch behavior. Chrome cannot optimize the pipeline when any non-passive handler exists on the element.

**Fix:** Gate the entire feature behind `localStorage.enablePinchZoom` (default=disabled) so handlers are never registered unless opted in.

**Lesson:** If a feature intercepts touch events, it MUST be feature-gated from day one. Do not register non-passive touch handlers unconditionally.

**Why emulator tests missed this:** `adb shell input swipe` creates perfectly clean single-touch events. The interference that blocked scroll on a real phone (imprecise finger contacts, Chrome handler scheduling, `passive: false` performance consequences) doesn't occur with synthetic ADB input.

## Case: Scroll direction bug, SGR btn 64/65 (Category 2)

Discovered after scroll was unblocked. SGR button semantics are counterintuitive on phones: phone-native convention (swipe up = newer) is the opposite of desktop scroll wheel (wheel up = older).

**Fix:** Direction-aware assertions using labeled scrollback content. Never assert only "content changed."

**Lesson:** Test assertions that only check "content changed" will pass regardless of direction. Always include directional markers in test content.

## Case: xterm.js built-in touch scroll overriding our handler (Category 1)

xterm.js v6 registers `touchstart`/`touchmove`/`touchend` on `document` (bubble phase, passive:false). Our handler in ime.ts runs in capture phase on `#terminal`. Both process the same events; last `scrollLines()` call wins. Since xterm's runs after ours (bubble after capture), xterm always overrides our programmatic scroll direction.

**Symptom:** Direction fix in our handler has ZERO effect on viewportY.

**Diagnosis:** `grep -c 'touchstart\|touchmove' node_modules/@xterm/xterm/lib/xterm.js` reveals xterm's handlers.

**Fix:** `e.stopPropagation()` in our capture-phase handler after claiming the gesture (`_isTouchScroll = true`), combined with `e.preventDefault()`.

**Lesson:** Phase 1a Handler Inventory must include library source, not just `src/`.

## Case: ADB coordinates missing terminal entirely (Category 0)

`measureScreenOffset()` uses a CDP touch probe to measure the gap between CSS viewport and ADB screen-absolute coordinates. When this fails (returns 0), ADB swipe coordinates are wrong.

**Symptom:** `bounds.top` is negative (-120). ADB swipe starts above screen. Zero touchmove events. viewportY appears to change, but only because shell output auto-scrolled to bottom.

**Diagnosis:** Phase 0 instrumentation immediately showed zero touchmove and negative coordinates. Without instrumentation, this looks identical to "scroll direction wrong."

**Lesson:** Always validate `bounds.top >= 0` and `bounds.bottom > bounds.top` before using ADB coordinates. This is Category 0, not Category 1 or 2.

## Case: Chrome compositor consuming ADB swipe (Category 0)

Chrome's compositor handles scrollable content by default. ADB `input swipe` generates touch events that Chrome recognizes as native scroll, consuming them at compositor level. Zero DOM events dispatched to JavaScript.

**Fix:** `touch-action: none` on the target element tells Chrome's compositor not to handle the gesture natively. With this CSS, ADB swipe delivers ~57 events per 1000ms swipe.

**Key facts:**
- `passive` flag is irrelevant; CSS `touch-action` controls compositor behavior
- ADB tap always delivers events (not recognized as scroll gesture)
- Progressive isolation (Phase 0.5) correctly identified this: L0 = 0 events, L1 (with touch-action:none) = 57 events

## Case: ADB touch pipeline cold-start (Category 0)

Chrome Android has a cold-start period where the first ADB swipes after page load deliver 0 events.

**Fix:** 2 throwaway "warmup" swipes before assertions. User observed this as "scrolling hesitancy" in production.

**Diagnostic trap:** A test running alone fails, but passes when run after other tests (which incidentally warm up the pipeline). Looks like inter-test interference, but is the opposite.

## Case: Native Chrome dialog blocking all ADB events (Category 0)

A Google Password Manager "Change your password" dialog covered the entire Chrome screen, silently intercepting ALL ADB touch/swipe events. CDP `page.evaluate()` still worked (DevTools protocol, not touch pipeline). Playwright/CDP cannot see or interact with native Android UI.

**Root cause of ADB gesture testing retirement.** After fixing cold-start, coordinate translation, and compositor issues, the next blocker was a native dialog that no web-only tool can handle. Each fix exposed the next ADB failure mode.

**Lesson:** Any tool that only sees web content will eventually be defeated by native dialogs, permission prompts, or Chrome updates. Mobile testing MUST interact with the full device UI. This is what Appium solves.

## Case: Guessing before observing (process failure)

5 consecutive test cycles spent trying fixes (direction inversion, selective stopPropagation, aggressive stopPropagation on all handlers). Each cycle: TypeScript compile + server restart + 3-minute emulator run. The aggressive stopPropagation attempt caused a regression (19/9, down from 21/7) by breaking pinch-to-zoom.

A single instrumented observation run (Phase 0) immediately showed: zero touchmove events, negative ADB coordinates, keyboard not dismissed.

**Lesson:** For gesture debugging, one observation run costs the same as one fix attempt but narrows the search space from "anything" to "here is exactly what happened." Always instrument first.

## Case: Duplicate handler registration (Category 1)

LLMs commonly add new handlers without removing old ones. Semgrep `duplicate-event-listener` rule catches this instantly. When `nosemgrep` is used, the comment MUST explain why the duplicate is intentional.

## Case: Stale server serving old JS (Category 0)

TypeScript compilation writes to `public/modules/*.js`. `server-ctl.sh ensure` checks git hash (committed code), not file modification time. Compiling without committing means `ensure` reports "healthy at HEAD" while serving old code.

**Fix:** `scripts/server-ctl.sh restart` after uncommitted TypeScript changes. Verify with `curl -s http://localhost:8081/modules/<file>.js | grep '<marker>'`.
