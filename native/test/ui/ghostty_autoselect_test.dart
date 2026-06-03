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

  group('GhosttySelectionDriver.click — tap forwards a CLICK (#693)', () {
    test('click emits press THEN release at the SAME cell, no motion', () {
      final sent = <String>[];
      final driver = GhosttySelectionDriver(onReport: sent.add);
      driver.click(col: 12, row: 3);
      expect(sent, ['\x1b[<0;12;3M', '\x1b[<0;12;3m']);
    });

    test('click is self-contained: a second click is independent', () {
      final sent = <String>[];
      final driver = GhosttySelectionDriver(onReport: sent.add);
      driver.click(col: 1, row: 1);
      driver.click(col: 40, row: 1); // status bar: another window tab
      expect(sent, [
        '\x1b[<0;1;1M',
        '\x1b[<0;1;1m',
        '\x1b[<0;40;1M',
        '\x1b[<0;40;1m',
      ]);
    });

    test('click leaves the driver inactive (release self-closes)', () {
      final sent = <String>[];
      final driver = GhosttySelectionDriver(onReport: sent.add);
      driver.click(col: 5, row: 5);
      sent.clear();
      // A stray motion after a click is a no-op (the click already released).
      driver.motion(col: 6, row: 5);
      driver.release();
      expect(sent, isEmpty);
    });
  });

  group('ghosttyTapClickReports — pure tap->click SGR sequence (#693)', () {
    test('is press then release at the same cell, in order', () {
      expect(ghosttyTapClickReports(col: 7, row: 2), [
        '\x1b[<0;7;2M',
        '\x1b[<0;7;2m',
      ]);
    });

    test('matches what the driver emits for the same cell', () {
      final sent = <String>[];
      GhosttySelectionDriver(onReport: sent.add).click(col: 9, row: 4);
      expect(ghosttyTapClickReports(col: 9, row: 4), sent);
    });

    test('1-based coordinates are emitted verbatim (top-left tab)', () {
      expect(ghosttyTapClickReports(col: 1, row: 1), [
        '\x1b[<0;1;1M',
        '\x1b[<0;1;1m',
      ]);
    });
  });

  group('ghosttyTapShouldForwardClick — click only under mouse mode (#693)', () {
    test(
      'forwards the click only when the overlay is active (mouse mode on)',
      () {
        expect(ghosttyTapShouldForwardClick(active: true), isTrue);
      },
    );

    test('does NOT forward a click in a plain shell (overlay inactive)', () {
      // A plain-shell tap must focus + raise the keyboard but emit NO SGR bytes,
      // so escape bytes never land as literal text on the shell.
      expect(ghosttyTapShouldForwardClick(active: false), isFalse);
    });
  });

  group('tap end-to-end: cell mapping feeds the click (#693)', () {
    test('a tap pixel maps to a cell that produces the click reports', () {
      // 800/80 = 10px cols, 600/24 = 25px rows. Tap at (45, 60):
      // col floor(45/10)=4 -> 5 (1-based); row floor(60/25)=2 -> 3 (1-based).
      final (col, row) = ghosttyCellForPosition(
        dx: 45,
        dy: 60,
        width: 800,
        height: 600,
        cols: 80,
        rows: 24,
      );
      expect((col, row), (5, 3));
      expect(ghosttyTapClickReports(col: col, row: row), [
        '\x1b[<0;5;3M',
        '\x1b[<0;5;3m',
      ]);
    });
  });

  group('ghosttySgrWheel* — SGR-1006 wheel byte encoding (#693)', () {
    test(
      'wheel-up is CSI < 64 ; col ; row M (WheelUpStatus → prev-window)',
      () {
        expect(ghosttySgrWheelUp(col: 1, row: 24), '\x1b[<64;1;24M');
      },
    );

    test('wheel-down is CSI < 65 ; col ; row M (WheelDownStatus → next)', () {
      expect(ghosttySgrWheelDown(col: 1, row: 24), '\x1b[<65;1;24M');
    });

    test('coordinates are emitted verbatim (already 1-based)', () {
      expect(ghosttySgrWheelUp(col: 3, row: 50), '\x1b[<64;3;50M');
      expect(ghosttySgrWheelDown(col: 3, row: 50), '\x1b[<65;3;50M');
    });
  });

  group('ghosttyWindowSwitchForSwipe — direction + threshold (#693)', () {
    const threshold = kGhosttyWindowSwitchThreshold; // 32px

    test('swipe LEFT past threshold → next-window (wheel-down)', () {
      expect(
        ghosttyWindowSwitchForSwipe(-threshold, threshold),
        GhosttyWindowSwitch.next,
      );
      expect(
        ghosttyWindowSwitchForSwipe(-200, threshold),
        GhosttyWindowSwitch.next,
      );
    });

    test('swipe RIGHT past threshold → previous-window (wheel-up)', () {
      expect(
        ghosttyWindowSwitchForSwipe(threshold, threshold),
        GhosttyWindowSwitch.previous,
      );
      expect(
        ghosttyWindowSwitchForSwipe(200, threshold),
        GhosttyWindowSwitch.previous,
      );
    });

    test('sub-threshold travel (either direction) → none', () {
      expect(
        ghosttyWindowSwitchForSwipe(threshold - 1, threshold),
        GhosttyWindowSwitch.none,
      );
      expect(
        ghosttyWindowSwitchForSwipe(-(threshold - 1), threshold),
        GhosttyWindowSwitch.none,
      );
      expect(
        ghosttyWindowSwitchForSwipe(0, threshold),
        GhosttyWindowSwitch.none,
      );
    });

    test('boundary: exactly ±threshold counts (inclusive)', () {
      expect(
        ghosttyWindowSwitchForSwipe(threshold, threshold),
        GhosttyWindowSwitch.previous,
      );
      expect(
        ghosttyWindowSwitchForSwipe(-threshold, threshold),
        GhosttyWindowSwitch.next,
      );
    });
  });

  group(
    'ghosttyStatusRowCell — wheel report targets the status row (#693)',
    () {
      test('default status-position bottom → last grid row, col 1', () {
        expect(ghosttyStatusRowCell(rows: 24), (1, 24));
        expect(ghosttyStatusRowCell(rows: 50), (1, 50));
      });
    },
  );

  group('swipe end-to-end: dx + status row feed the wheel report (#693)', () {
    test('swipe LEFT emits one wheel-DOWN at the status row (next-window)', () {
      final decision = ghosttyWindowSwitchForSwipe(
        -64,
        kGhosttyWindowSwitchThreshold,
      );
      expect(decision, GhosttyWindowSwitch.next);
      final (col, row) = ghosttyStatusRowCell(rows: 24);
      expect(ghosttySgrWheelDown(col: col, row: row), '\x1b[<65;1;24M');
    });

    test('swipe RIGHT emits one wheel-UP at the status row (prev-window)', () {
      final decision = ghosttyWindowSwitchForSwipe(
        64,
        kGhosttyWindowSwitchThreshold,
      );
      expect(decision, GhosttyWindowSwitch.previous);
      final (col, row) = ghosttyStatusRowCell(rows: 24);
      expect(ghosttySgrWheelUp(col: col, row: row), '\x1b[<64;1;24M');
    });

    test('a near-vertical swipe (tiny dx) switches no window', () {
      expect(
        ghosttyWindowSwitchForSwipe(5, kGhosttyWindowSwitchThreshold),
        GhosttyWindowSwitch.none,
      );
    });
  });
}
