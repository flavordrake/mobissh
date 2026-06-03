// #717 — On the Ghostty backend, first-connect vertical scroll is DEAD until
// the keyboard is raised. Root cause: flterm's `TerminalView` is built
// `autofocus: false`, so on connect the terminal isn't focused and flterm's
// scroll/interaction is inert until a tap raises the keyboard (which finally
// focuses it). The fix focuses the terminal ONCE per connect (tied to the proxy
// `shellReady` stream) via `controller.requestFocus()` — focus ONLY, NOT
// `showKeyboard()` (#693/#706 separated focus from the IME, so the keyboard must
// NOT auto-pop on connect; a later tap still raises it).
//
// flterm/libghostty can't render headless (native .so), so these gate the PURE
// decision the focus path uses (when to requestFocus). The keyboard staying
// down + first-connect scroll working with no tap are OWNER-validated on device.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('ghosttyShouldFocusOnConnect — when to focus on connect (#717)', () {
    test(
      'focuses when ACTIVE, connected, and not yet focused (the fix case)',
      () {
        // The bug case made concrete: this is the visible session's view, the
        // shell is live, and we haven't focused yet this connect — so focus the
        // terminal (focus only, no keyboard) so scroll works immediately.
        expect(
          ghosttyShouldFocusOnConnect(
            active: true,
            connected: true,
            alreadyFocused: false,
          ),
          isTrue,
        );
      },
    );

    test('does NOT focus a BACKGROUND (offstage) session view', () {
      // _SessionTerminalBody renders every session in an IndexedStack, so a
      // non-active session's view is mounted but offstage. Focusing it would
      // STEAL focus from the visible session — don't fight focus across sessions.
      expect(
        ghosttyShouldFocusOnConnect(
          active: false,
          connected: true,
          alreadyFocused: false,
        ),
        isFalse,
      );
    });

    test('does NOT focus before the session is connected', () {
      // A dead PTY has nothing to interact with; gating on connected means a
      // pre-connect tick no-ops.
      expect(
        ghosttyShouldFocusOnConnect(
          active: true,
          connected: false,
          alreadyFocused: false,
        ),
        isFalse,
      );
    });

    test('fires ONCE per connect — does not re-focus once already focused', () {
      // The per-connect latch prevents stealing focus on every rebuild (e.g.
      // from the compose bar). After the first focus this returns false until
      // the latch is reset (on the next shellReady / reconnect).
      expect(
        ghosttyShouldFocusOnConnect(
          active: true,
          connected: true,
          alreadyFocused: true,
        ),
        isFalse,
      );
    });

    test('requires ALL guards — any single false blocks the focus', () {
      // Exhaustive: focus only when active AND connected AND not-yet-focused.
      for (final active in [true, false]) {
        for (final connected in [true, false]) {
          for (final alreadyFocused in [true, false]) {
            final expected = active && connected && !alreadyFocused;
            expect(
              ghosttyShouldFocusOnConnect(
                active: active,
                connected: connected,
                alreadyFocused: alreadyFocused,
              ),
              expected,
              reason:
                  'active=$active connected=$connected '
                  'alreadyFocused=$alreadyFocused',
            );
          }
        }
      }
    });
  });
}
