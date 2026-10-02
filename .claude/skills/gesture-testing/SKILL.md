---
name: gesture-testing
description: Use when debugging touch/gesture issues on Android emulator, when a gesture feature is added or modified, when emulator tests pass but device testing fails, or when the user says "diagnose gestures", "debug touch", "gesture audit", "why aren't touches working", "scroll not working", "pinch broken", or "gesture interaction".
---

# Gesture Testing

Guide for developing and debugging touch gesture features in the native app. The
on-emulator integration tests are the ground truth: when a gesture change breaks one
that is `expect` in `native/integration_test/BASELINE.manifest`, the change has a
regression — fix the code, not the test.

## Resources (same directory)

- **[case-studies.md](case-studies.md)** — historical bugs with root causes and fixes.
  Written against the retired PWA; the lessons (observe before changing, direction-aware
  assertions) carry over, the file paths do not.
- **[instrumentation-cookbook.md](instrumentation-cookbook.md)** — PWA-era tracing
  recipes; use them as a pattern, not as code to run.

## Where gestures live

- `native/lib/ui/ghostty_terminal_view.dart` — the terminal view and its gesture routing
- `native/lib/ui/terminal_mouse_handler.dart` — touch → SGR mouse reports for tmux
- `native/lib/ui/gutter_line_select_layer.dart`, `ghostty_gutter_layer.dart` — gutter selection and chips
- `native/lib/diagnostics/gesture_trace.dart` — `gtrace(...)` ring buffer, logcat tag
  `[GESTURE]`, attached to every bug report

## Tests that cover gestures

- `golden_flow_tui_test.dart`, `gutter_copy_scrollback_test.dart` — run by
  `scripts/terminal-flow-gate.sh`, REQUIRED before shipping any gesture-routing change.
  Gesture-model changes update these tests in the same commit.
- `cc_gestures_test.dart`, `tmux_scrollback_test.dart`, `disconnected_scroll_test.dart`,
  `gutter_track_scroll_993_test.dart`, `tmux_status_tap_sgr_test.dart` — scroll, tap
  and SGR paths

Run a named subset over one emulator lease:

```bash
scripts/with-fleet-emulator.sh -- scripts/integration-subset.sh integration_test/cc_gestures_test.dart
```

## Adding a New Gesture Feature

1. **Handler inventory.** Before writing code, list every `GestureDetector`,
   `Listener` and `RawGestureDetector` on the terminal path (`ui/ghostty_terminal_view.dart`
   and the layers above it). Build a table: widget | callbacks | arena behaviour | feature.
   Gesture-arena conflicts are the native equivalent of a swallowed touch event.
2. **Write the test first.** A new test in `native/integration_test/` declares its own
   fixtures in its header (#1101) and needs a manifest line plus a tally bump.
   Prefer a headless widget test in `native/test/` when the gesture logic can be driven
   with `tester.drag`/`tester.tap` without a real device.
3. **Direction-aware assertions.** Never assert only "content changed". Seed scrollback
   with ordered markers and assert which end is visible after the swipe.
4. **Run the terminal-flow gate** (`scripts/terminal-flow-gate.sh`) plus the new test.

## Debugging a Gesture Failure

**Observe before changing.** One instrumented run reveals the problem faster than
several fix-build-test cycles.

| Category | Symptom | Approach |
|---|---|---|
| Test infra | Gesture never reaches the app | Check the emulator is live, dialogs, widget bounds |
| Arena conflict | Callback never runs, or another recognizer wins | Handler inventory, `gtrace` lines |
| Wrong behavior | Callback runs but output is incorrect | Direction assertions, SGR bytes in `[GESTURE]` lines |

Observation tools:

```bash
scripts/emu-shot.sh <label>      # screenshot to test-results/emulator-shots/, prints the path
scripts/emu-log.sh --clear       # clear logcat, reproduce, then:
scripts/emu-log.sh               # dump app+flutter logcat to a file, prints the path
```

Read the screenshot, grep the log for `[GESTURE]`. For on-device reports, the bug-report
bundle in `test-results/uploads/` carries the gesture ring.

## Positioning (synthetic input)

- Avoid screen edges (Android navigation gestures)
- Avoid keyboard boundary crossings
- Slight diagonal drift is more realistic than a perfectly vertical swipe
