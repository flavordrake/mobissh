// #741 — On the Ghostty backend, swiping the APP-LEVEL session bar to switch
// sessions DISMISSED the soft keyboard. Every session's terminal is mounted in
// an IndexedStack (terminal_screen.dart); a swipe-switch changes the visible
// index, so the outgoing (focused) flterm view goes OFFSTAGE — its TextInput
// connection detaches and the keyboard collapses — while the incoming view is
// never focused and never re-shows the keyboard. The bar then jumps down out
// from under the finger (the keyboard inset vanished mid-gesture).
//
// The fix keeps the keyboard state UNCHANGED across a switch:
//   - the OUTGOING view records whether its keyboard was up (showing) at the
//     moment it stops being active;
//   - the INCOMING view re-attaches focus and, if the keyboard WAS up, re-shows
//     it on the newly-active terminal so the IME never collapses; if it was
//     down, focus only (the keyboard stays down).
//
// flterm/libghostty can't render headless (native .so), so these gate the PURE
// decisions the switch-focus path uses. The real keyboard NOT dropping (and the
// bar staying put under the finger) is OWNER-validated on device.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group(
    'ghosttyShouldCaptureKeyboardOnSessionSwitch — outgoing view (#741)',
    () {
      test('captures when THIS view is the one LEAVING active (fix case)', () {
        // prev == this session, next == some OTHER session: this view is the
        // outgoing one, so it records whether its keyboard was up before the
        // incoming view restores it.
        expect(
          ghosttyShouldCaptureKeyboardOnSessionSwitch(
            sessionId: 's-old',
            prevActiveId: 's-old',
            nextActiveId: 's-new',
          ),
          isTrue,
        );
      });

      test('does NOT capture for a view that was already inactive', () {
        // A third, already-background session sees the same provider tick but it
        // was never active — it must not clobber the captured flag.
        expect(
          ghosttyShouldCaptureKeyboardOnSessionSwitch(
            sessionId: 's-bg',
            prevActiveId: 's-old',
            nextActiveId: 's-new',
          ),
          isFalse,
        );
      });

      test('does NOT capture when the active session did not change', () {
        // A spurious re-emit of the same active id is not a switch.
        expect(
          ghosttyShouldCaptureKeyboardOnSessionSwitch(
            sessionId: 's-old',
            prevActiveId: 's-old',
            nextActiveId: 's-old',
          ),
          isFalse,
        );
      });

      test('does NOT capture on the FIRST tick (no previous active)', () {
        // prev == null is the initial activation, not a switch away from a
        // keyboard-up session.
        expect(
          ghosttyShouldCaptureKeyboardOnSessionSwitch(
            sessionId: 's-old',
            prevActiveId: null,
            nextActiveId: 's-old',
          ),
          isFalse,
        );
      });
    },
  );

  group('ghosttyShouldRestoreFocusOnSessionSwitch — incoming view (#741)', () {
    test('restores when THIS view BECOMES active from another (fix case)', () {
      // next == this session, prev == a DIFFERENT non-null session: this is
      // the incoming view of a real swipe-switch, so it re-attaches focus
      // (and the caller re-shows the keyboard iff it was up).
      expect(
        ghosttyShouldRestoreFocusOnSessionSwitch(
          sessionId: 's-new',
          prevActiveId: 's-old',
          nextActiveId: 's-new',
        ),
        isTrue,
      );
    });

    test('does NOT restore for a view that stays in the background', () {
      expect(
        ghosttyShouldRestoreFocusOnSessionSwitch(
          sessionId: 's-bg',
          prevActiveId: 's-old',
          nextActiveId: 's-new',
        ),
        isFalse,
      );
    });

    test('does NOT restore when the active session did not change', () {
      expect(
        ghosttyShouldRestoreFocusOnSessionSwitch(
          sessionId: 's-new',
          prevActiveId: 's-new',
          nextActiveId: 's-new',
        ),
        isFalse,
      );
    });

    test('does NOT restore on the FIRST activation (no previous session)', () {
      // The initial connect-focus path (#717) handles first activation. A
      // switch-restore only applies when there is a PREVIOUS session to switch
      // away FROM — else it would fight the per-connect focus latch and could
      // raise the keyboard on cold start (the #693/#717 IME separation).
      expect(
        ghosttyShouldRestoreFocusOnSessionSwitch(
          sessionId: 's-new',
          prevActiveId: null,
          nextActiveId: 's-new',
        ),
        isFalse,
      );
    });
  });

  group(
    'ghosttyShouldShowKeyboardOnSessionSwitch — IME restore gate (#741)',
    () {
      test('shows the keyboard only when it was up before the switch', () {
        // The whole point: leave the keyboard state UNCHANGED. Up before → up
        // after (re-show on the incoming terminal); down before → stays down.
        expect(
          ghosttyShouldShowKeyboardOnSessionSwitch(keyboardWasUp: true),
          isTrue,
        );
        expect(
          ghosttyShouldShowKeyboardOnSessionSwitch(keyboardWasUp: false),
          isFalse,
        );
      });
    },
  );
}
