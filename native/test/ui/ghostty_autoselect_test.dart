// #692 — Ghostty: auto long-press select (drop the #688 mode toggle) + Select All.
//
// The gesture decides: a finger SWIPE (move-first) scrolls (#690); a deliberate
// LONG-PRESS (held stationary) then drag starts a SELECTION. We drive the
// selection OURSELVES — flterm 0.0.3 does not export its pixel->cell mapping or
// its native `MouseEncoder`, and libghostty's `MouseEncoder` is native FFI (not
// headless-testable). So on a long-press-drag we synthesise SGR-1006 mouse
// reports (button1 press at the long-pressed cell, motion as the finger drags,
// release on lift) and send them to the remote via `proxy.sendInput`; tmux then
// runs its OWN native, precise selection.
//
// flterm/libghostty can't render headless (native .so), so these gate the PURE
// pieces: pixel->cell mapping, the SGR byte encoding, and the press/motion/
// release state machine (the [GhosttySelectionDriver]). The real on-device tmux
// selection is OWNER-validated.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  group('ghosttyCellForPosition — pixel -> 1-based viewport cell (#692)', () {
    test('top-left pixel maps to cell (1, 1)', () {
      final (col, row) = ghosttyCellForPosition(
        dx: 0,
        dy: 0,
        width: 800,
        height: 600,
        cols: 80,
        rows: 24,
      );
      expect(col, 1);
      expect(row, 1);
    });

    test('a pixel mid-grid maps to the containing cell (1-based)', () {
      // 800/80 = 10px cols, 600/24 = 25px rows. (105, 70) -> col floor(105/10)=10
      // (0-based) -> 11 (1-based); row floor(70/25)=2 -> 3 (1-based).
      final (col, row) = ghosttyCellForPosition(
        dx: 105,
        dy: 70,
        width: 800,
        height: 600,
        cols: 80,
        rows: 24,
      );
      expect(col, 11);
      expect(row, 3);
    });

    test('the bottom-right pixel clamps to the last cell (cols, rows)', () {
      final (col, row) = ghosttyCellForPosition(
        dx: 800,
        dy: 600,
        width: 800,
        height: 600,
        cols: 80,
        rows: 24,
      );
      expect(col, 80);
      expect(row, 24);
    });

    test('negative / out-of-range pixels clamp into the grid (>=1, <=max)', () {
      final (col, row) = ghosttyCellForPosition(
        dx: -50,
        dy: -50,
        width: 800,
        height: 600,
        cols: 80,
        rows: 24,
      );
      expect(col, 1);
      expect(row, 1);

      final (col2, row2) = ghosttyCellForPosition(
        dx: 100000,
        dy: 100000,
        width: 800,
        height: 600,
        cols: 80,
        rows: 24,
      );
      expect(col2, 80);
      expect(row2, 24);
    });

    test('degenerate grid (zero cols/rows or size) never divides by zero', () {
      for (final bad in const [
        (0, 24, 800.0, 600.0),
        (80, 0, 800.0, 600.0),
        (80, 24, 0.0, 600.0),
        (80, 24, 800.0, 0.0),
      ]) {
        final (c, r, w, h) = bad;
        final (col, row) = ghosttyCellForPosition(
          dx: 10,
          dy: 10,
          width: w,
          height: h,
          cols: c,
          rows: r,
        );
        expect(col, greaterThanOrEqualTo(1));
        expect(row, greaterThanOrEqualTo(1));
      }
    });
  });

  group('ghosttySgrMouse* — SGR-1006 byte encoding (#692)', () {
    test('press is CSI < 0 ; col ; row M (uppercase, button1 down)', () {
      expect(ghosttySgrMousePress(col: 5, row: 3), '\x1b[<0;5;3M');
    });

    test('motion is CSI < 32 ; col ; row M (motion bit + button1)', () {
      expect(ghosttySgrMouseMotion(col: 7, row: 9), '\x1b[<32;7;9M');
    });

    test('release is CSI < 0 ; col ; row m (lowercase m)', () {
      expect(ghosttySgrMouseRelease(col: 5, row: 3), '\x1b[<0;5;3m');
    });

    test('coordinates are emitted verbatim (already 1-based)', () {
      expect(ghosttySgrMousePress(col: 1, row: 1), '\x1b[<0;1;1M');
      expect(ghosttySgrMouseRelease(col: 80, row: 24), '\x1b[<0;80;24m');
    });
  });

  group('GhosttySelectionDriver — press/motion(dedup)/release (#692)', () {
    test('press emits exactly one button1-down report at the start cell', () {
      final sent = <String>[];
      final driver = GhosttySelectionDriver(onReport: sent.add);
      driver.press(col: 4, row: 2);
      expect(sent, ['\x1b[<0;4;2M']);
    });

    test('motion before press is ignored (no selection in progress)', () {
      final sent = <String>[];
      final driver = GhosttySelectionDriver(onReport: sent.add);
      driver.motion(col: 9, row: 9);
      expect(sent, isEmpty);
    });

    test('motion emits a report only when the cell CHANGES (dedup)', () {
      final sent = <String>[];
      final driver = GhosttySelectionDriver(onReport: sent.add);
      driver.press(col: 4, row: 2);
      driver.motion(col: 4, row: 2); // same as press cell -> no report
      driver.motion(col: 5, row: 2); // changed -> report
      driver.motion(col: 5, row: 2); // same -> no report
      driver.motion(col: 5, row: 3); // changed -> report
      expect(sent, [
        '\x1b[<0;4;2M', // press
        '\x1b[<32;5;2M', // motion to (5,2)
        '\x1b[<32;5;3M', // motion to (5,3)
      ]);
    });

    test('release emits a button-up report at the last cell and ends', () {
      final sent = <String>[];
      final driver = GhosttySelectionDriver(onReport: sent.add);
      driver.press(col: 4, row: 2);
      driver.motion(col: 6, row: 2);
      driver.release();
      expect(sent.last, '\x1b[<0;6;2m');
    });

    test(
      'release at the press cell (no drag) still reports up at that cell',
      () {
        final sent = <String>[];
        final driver = GhosttySelectionDriver(onReport: sent.add);
        driver.press(col: 4, row: 2);
        driver.release();
        expect(sent, ['\x1b[<0;4;2M', '\x1b[<0;4;2m']);
      },
    );

    test('release without press is a no-op (no stray up report)', () {
      final sent = <String>[];
      final driver = GhosttySelectionDriver(onReport: sent.add);
      driver.release();
      expect(sent, isEmpty);
    });

    test('a second press after release starts a fresh selection', () {
      final sent = <String>[];
      final driver = GhosttySelectionDriver(onReport: sent.add);
      driver.press(col: 1, row: 1);
      driver.release();
      sent.clear();
      driver.press(col: 8, row: 8);
      driver.motion(col: 9, row: 8);
      driver.release();
      expect(sent, ['\x1b[<0;8;8M', '\x1b[<32;9;8M', '\x1b[<0;9;8m']);
    });
  });
}
