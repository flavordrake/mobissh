// #720 — on the Ghostty backend, returning from a device UNLOCK (or any resume
// where focus was RETAINED and the grid size didn't change) shows a STALE view
// until a tap. #718's resume re-focus is a NO-OP in that case: focus was
// retained through the lock, so `controller.requestFocus()` doesn't change focus
// → flterm's `_onFocusChanged` never fires → no `notifyListeners()` → the
// RenderTerminal never `markNeedsPaint()`s. (The tap repaints only because it
// forwards an SGR click → tmux emits output → repaint.)
//
// The fix forces a real flterm repaint via a FOCUS CYCLE — `controller.unfocus()`
// then `controller.requestFocus()` on a POST-FRAME callback, so the FocusNode
// genuinely transitions (focused → unfocused → focused) and `_onFocusChanged`
// fires the notify → repaint. It NEVER calls `showKeyboard()`, so the keyboard
// stays down; and it is active-session-guarded so an offstage session's view
// doesn't steal focus.
//
// flterm/libghostty can't render headless (native .so), so this gates the PURE
// decision: WHEN to force the focus-cycle repaint. The real flterm repaint
// (unlock + app-switch show the latest immediately, no tap, keyboard down) is
// OWNER-validated on device.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('ghosttyShouldCycleFocusForRepaint — force repaint on resume (#720)', () {
    test(
      'cycles focus when ACTIVE, connected, and focus was RETAINED (fix case)',
      () {
        // The unlock case made concrete: the visible session's view, a live
        // shell, and focus is STILL held (retained through the lock). A plain
        // requestFocus() is a no-op here, so we must cycle focus to repaint.
        expect(
          ghosttyShouldCycleFocusForRepaint(
            active: true,
            connected: true,
            hasFocus: true,
          ),
          isTrue,
        );
      },
    );

    test(
      'does NOT cycle when focus was LOST (plain refocus already repaints)',
      () {
        // If focus was lost while backgrounded, the #718 requestFocus() drives a
        // real focus change (unfocused → focused) → repaint, so cycling is
        // redundant. Gate it out so we don't double-handle the common case.
        expect(
          ghosttyShouldCycleFocusForRepaint(
            active: true,
            connected: true,
            hasFocus: false,
          ),
          isFalse,
        );
      },
    );

    test('does NOT cycle a BACKGROUND (offstage) session view', () {
      // _SessionTerminalBody renders every session in an IndexedStack, so a
      // non-active session's view is mounted but offstage. Cycling its focus
      // would steal focus from the visible session — same guard as #717/#718.
      expect(
        ghosttyShouldCycleFocusForRepaint(
          active: false,
          connected: true,
          hasFocus: true,
        ),
        isFalse,
      );
    });

    test('does NOT cycle a disconnected session', () {
      // A dead PTY has nothing to repaint — the resume repaint no-ops, matching
      // the connected-only guard the connect/resume focus paths use.
      expect(
        ghosttyShouldCycleFocusForRepaint(
          active: true,
          connected: false,
          hasFocus: true,
        ),
        isFalse,
      );
    });

    test('requires ALL guards — any single false blocks the focus cycle', () {
      // Exhaustive: cycle focus only when active AND connected AND currently
      // focused (the retained-focus unlock case the plain refocus can't fix).
      for (final active in [true, false]) {
        for (final connected in [true, false]) {
          for (final hasFocus in [true, false]) {
            final expected = active && connected && hasFocus;
            expect(
              ghosttyShouldCycleFocusForRepaint(
                active: active,
                connected: connected,
                hasFocus: hasFocus,
              ),
              expected,
              reason: 'active=$active connected=$connected hasFocus=$hasFocus',
            );
          }
        }
      }
    });
  });
}
