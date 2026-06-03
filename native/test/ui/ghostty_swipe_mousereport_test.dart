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
  group('ghosttySwipeShouldScrollLocally — when to intercept (#690)', () {
    test('intercepts when mouse mode is ON and select mode is OFF', () {
      // The bug case: tmux has mouse on; a swipe would be a remote drag.
      for (final mode in const [
        MouseTracking.any,
        MouseTracking.button,
        MouseTracking.normal,
        MouseTracking.x10,
      ]) {
        expect(
          ghosttySwipeShouldScrollLocally(
            mouseTracking: mode,
            selectMode: false,
          ),
          isTrue,
          reason: 'mouse mode $mode + no select mode → swipe must scroll',
        );
      }
    });

    test('does NOT intercept when the remote has no mouse tracking', () {
      // No mouse mode → flterm never forwards a drag; its own Scrollable scrolls.
      expect(
        ghosttySwipeShouldScrollLocally(
          mouseTracking: MouseTracking.none,
          selectMode: false,
        ),
        isFalse,
      );
    });

    test('does NOT intercept while DELIBERATE select mode is on', () {
      // #688's select mode must keep working: long-press-drag selection stays
      // flterm-native, so the overlay steps aside even under mouse tracking.
      for (final mode in const [
        MouseTracking.any,
        MouseTracking.button,
        MouseTracking.normal,
        MouseTracking.x10,
      ]) {
        expect(
          ghosttySwipeShouldScrollLocally(
            mouseTracking: mode,
            selectMode: true,
          ),
          isFalse,
          reason: 'select mode is deliberate → do not steal the gesture',
        );
      }
    });

    test('select mode off + no mouse tracking is also not intercepted', () {
      expect(
        ghosttySwipeShouldScrollLocally(
          mouseTracking: MouseTracking.none,
          selectMode: true,
        ),
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
