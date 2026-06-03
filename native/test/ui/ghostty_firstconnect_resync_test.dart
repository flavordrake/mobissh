// #702 — Ghostty first-connect layout fails because the #666/#659 fit-burst
// (`[ui.fit659]` in terminal_screen.dart) is XTERM-ONLY: it hunts for xterm's
// `TerminalViewState`, which is offstage on the ghostty backend, so the burst
// NEVER runs and the only PTY resize is the one fired BEFORE `shellReady` (the
// classic #666 drop). tmux then keeps the stale pre-shellReady size and the
// first-connect layout is wrong.
//
// The fix is a ghostty-LOCAL post-shellReady forced resize re-sync: on
// `shellReady` (and a short follow-up burst) re-send the CURRENT grid even if
// unchanged, so tmux gets the real size AFTER the shell exists. The re-sync is
// gated by `ghosttyShouldResyncResize` — only fire when connected AND the grid
// is valid (flterm may not have laid out at the exact shellReady instant).
//
// flterm/libghostty can't render headless (native .so), so these gate the PURE
// decision the burst uses (when to re-send). The real tmux re-size + the
// first-connect layout filling correctly is OWNER-validated on device.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('ghosttyShouldResyncResize — when to force a re-sync (#702)', () {
    test('re-syncs when connected AND the grid is valid (the fix case)', () {
      // The bug case made concrete: the shell now exists (connected), flterm has
      // laid out a real grid (53 rows like the device repro), so re-send it so
      // tmux gets the post-shellReady size instead of the dropped pre-ready one.
      expect(
        ghosttyShouldResyncResize(connected: true, cols: 80, rows: 53),
        isTrue,
      );
    });

    test('does NOT re-sync before the shell exists (would be dropped)', () {
      // A resize sent before the task-side shell exists is discarded by
      // session_host's `s.shell?.resize` — exactly the #666 drop. Gating on
      // connected means the burst's early ticks no-op until the shell is live.
      expect(
        ghosttyShouldResyncResize(connected: false, cols: 80, rows: 53),
        isFalse,
      );
    });

    test('does NOT re-sync until flterm has laid out a valid grid', () {
      // flterm may not have computed `_cols`/`_rows` (> 0) at the exact
      // shellReady instant; the burst keeps re-trying. A 0-grid tick must no-op
      // so we never send an off-grid (0x0) resize.
      expect(
        ghosttyShouldResyncResize(connected: true, cols: 0, rows: 0),
        isFalse,
      );
      expect(
        ghosttyShouldResyncResize(connected: true, cols: 80, rows: 0),
        isFalse,
      );
      expect(
        ghosttyShouldResyncResize(connected: true, cols: 0, rows: 24),
        isFalse,
      );
    });

    test('does not re-sync with a negative grid (defensive)', () {
      expect(
        ghosttyShouldResyncResize(connected: true, cols: -1, rows: 24),
        isFalse,
      );
      expect(
        ghosttyShouldResyncResize(connected: true, cols: 80, rows: -1),
        isFalse,
      );
    });
  });

  group('kGhosttyResyncBurstMs — first-connect re-sync burst (#702)', () {
    test('mirrors the xterm #659/#666 burst delays (120/350/700/1200ms)', () {
      // At least one tick must land after flterm's grid settles (the device race
      // the emulator can\'t reproduce), so the burst spans short→long like the
      // xterm path. Strictly ascending, all positive.
      expect(kGhosttyResyncBurstMs, [120, 350, 700, 1200]);
      var prev = 0;
      for (final ms in kGhosttyResyncBurstMs) {
        expect(ms, greaterThan(prev));
        prev = ms;
      }
    });
  });
}
