// #690 — Ghostty: a touch swipe must SCROLL the scrollback, not be forwarded to
// the remote as a mouse-button DRAG (which tmux reads as a selection).
//
// flterm 0.0.3 exposes NO interception hook analogous to xterm's
// `Terminal.mouseHandler` (the #617 fix): its mouse-report path is internal to
// `TerminalGestureDetector` (a raw `Listener`, not an arena participant), and
// `TerminalGestureSettings` explicitly cannot disable mouse tracking. So the fix
// lives ABOVE the flterm widget — a pointer-absorbing overlay that, when the
// remote has mouse mode on and select mode is off, claims the touch swipe and
// scrolls the scroll controller (flterm then emits canonical wheel reports).
//
// flterm/libghostty can't render headless (native .so), so these gate the PURE
// decision + math the overlay uses. The two predicates fully determine when the
// drag is intercepted and which way the scrollback moves; the real tmux-mouse
// behaviour is OWNER-validated on device.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('ghosttySwipeShouldScrollLocally — when to intercept (#690, #692)', () {
    test('intercepts (overlay active) whenever mouse mode is ON', () {
      // The bug case: tmux has mouse on; flterm would forward raw touch. The
      // overlay then routes the gesture (swipe→scroll, long-press→select). #692
      // dropped the select-mode param — the gesture, not a mode, decides.
      for (final mode in const [
        MouseTracking.any,
        MouseTracking.button,
        MouseTracking.normal,
        MouseTracking.x10,
      ]) {
        expect(
          ghosttySwipeShouldScrollLocally(mouseTracking: mode),
          isTrue,
          reason: 'mouse mode $mode → overlay must intercept and route touch',
        );
      }
    });

    test('does NOT intercept when the remote has no mouse tracking', () {
      // No mouse mode → flterm never forwards a drag; its own Scrollable scrolls
      // and its native selection works. Overlay stays inert (plain shells work).
      expect(
        ghosttySwipeShouldScrollLocally(mouseTracking: MouseTracking.none),
        isFalse,
      );
    });
  });

  group('ghosttyScrollDeltaForSwipe — natural-direction scroll (#690)', () {
    test('dragging the finger DOWN scrolls toward older content (up)', () {
      // Finger down (+dy) reveals older lines = smaller pixel offset = negative.
      expect(ghosttyScrollDeltaForSwipe(24), -24);
    });

    test('dragging the finger UP scrolls toward newer content (down)', () {
      expect(ghosttyScrollDeltaForSwipe(-24), 24);
    });

    test('a still finger produces no scroll', () {
      expect(ghosttyScrollDeltaForSwipe(0), 0);
    });

    test('is exactly the negation of the finger delta', () {
      for (final dy in const [1.0, -1.0, 5.5, -120.0, 0.0]) {
        expect(ghosttyScrollDeltaForSwipe(dy), -dy);
      }
    });
  });
}
