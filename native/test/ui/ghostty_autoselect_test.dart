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
  // ghosttyMeasureCellSize lays out a TextPainter, which needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ghosttyMeasureCellSize — REAL flterm cell metrics (#699)', () {
    test('returns a positive cell whose height is at least its width', () {
      final size = ghosttyMeasureCellSize(
        fontSize: 14,
        fontFamily: 'monospace',
      );
      expect(size.width, greaterThan(0));
      expect(size.height, greaterThan(0));
      // A terminal cell's line height is >= its advance width. On a real device
      // it is strictly taller (the gap from overlayHeight/rows is the #699 bug);
      // the headless test font is square (no real glyph metrics), so assert >=.
      expect(size.height, greaterThanOrEqualTo(size.width));
    });

    test('a larger font produces a larger cell (height scales with size)', () {
      final small = ghosttyMeasureCellSize(
        fontSize: 10,
        fontFamily: 'monospace',
      );
      final large = ghosttyMeasureCellSize(
        fontSize: 20,
        fontFamily: 'monospace',
      );
      expect(large.height, greaterThan(small.height));
      expect(large.width, greaterThan(small.width));
    });

    test('a higher devicePixelRatio still ceil-snaps to a positive cell', () {
      final size = ghosttyMeasureCellSize(
        fontSize: 14,
        fontFamily: 'monospace',
        devicePixelRatio: 3.0,
      );
      expect(size.width, greaterThan(0));
      expect(size.height, greaterThan(0));
    });

    test(
      'a degenerate devicePixelRatio (<=0) is treated as 1.0, not a crash',
      () {
        final size = ghosttyMeasureCellSize(
          fontSize: 14,
          fontFamily: 'monospace',
          devicePixelRatio: 0,
        );
        expect(size.width, greaterThan(0));
        expect(size.height, greaterThan(0));
      },
    );
  });

  group('ghosttyCellForPosition — pixel -> 1-based viewport cell (#692/#699)', () {
    // #699 fix: the map now divides by the REAL flterm cell size (cellWidth/
    // cellHeight) and subtracts the 4px flterm padding, instead of deriving the
    // cell size from overlayHeight/rows (which is LARGER than the real cell
    // height, so the row index came out too small → selection ABOVE the press).
    // These cases use realistic metrics: 10px-wide / 17px-tall cells, padding 4.

    test('top-left of the GRID (just past padding) maps to cell (1, 1)', () {
      final (col, row) = ghosttyCellForPosition(
        dx: 4, // == padding: first inner pixel
        dy: 4,
        cellWidth: 10,
        cellHeight: 17,
        cols: 80,
        rows: 24,
      );
      expect(col, 1);
      expect(row, 1);
    });

    test('a touch inside the padding band still clamps to cell (1, 1)', () {
      // dx,dy < padding → innerDx/innerDy negative → floor < 0 → clamps to 1.
      final (col, row) = ghosttyCellForPosition(
        dx: 0,
        dy: 0,
        cellWidth: 10,
        cellHeight: 17,
        cols: 80,
        rows: 24,
      );
      expect(col, 1);
      expect(row, 1);
    });

    test(
      'a mid-grid pixel maps to the containing cell (padding subtracted)',
      () {
        // innerDx = 109-4 = 105 → floor(105/10)=10 → col 11.
        // innerDy = 174-4 = 170 → floor(170/17)=10 → row 11.
        final (col, row) = ghosttyCellForPosition(
          dx: 109,
          dy: 174,
          cellWidth: 10,
          cellHeight: 17,
          cols: 80,
          rows: 24,
        );
        expect(col, 11);
        expect(row, 11);
      },
    );

    test(
      '#699 REGRESSION: real cell height puts the touch AT the press row, '
      'not several rows above (the old overlayH/rows map would land high)',
      () {
        // Device-like: overlay 600px tall, 24 rows, but the REAL cell height is
        // 17px (24*17 = 408px of grid + 4px padding; the rest is slack).
        // Touch near the visual bottom of the grid, row 23:
        //   innerDy = 395-4 = 391 → floor(391/17)=23 → row 24 (1-based).
        const dy = 395.0;
        final (_, rowFixed) = ghosttyCellForPosition(
          dx: 50,
          dy: dy,
          cellWidth: 10,
          cellHeight: 17,
          cols: 80,
          rows: 24,
        );
        expect(rowFixed, 24, reason: 'maps to the row under the finger');

        // The OLD formula (cellHeight = overlayHeight/rows = 600/24 = 25px, no
        // padding) would have computed floor(395/25)=15 → row 16 — EIGHT rows
        // too high. Assert the fixed result is NOT that off-by-many row.
        final oldRow = (dy / (600 / 24)).floor() + 1;
        expect(oldRow, 16, reason: 'documents the buggy old result');
        expect(
          rowFixed,
          isNot(oldRow),
          reason: '#699: must not land rows above the press',
        );
        expect(rowFixed - oldRow, greaterThanOrEqualTo(4));
      },
    );

    test('the bottom-right pixel clamps to the last cell (cols, rows)', () {
      final (col, row) = ghosttyCellForPosition(
        dx: 100000,
        dy: 100000,
        cellWidth: 10,
        cellHeight: 17,
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
        cellWidth: 10,
        cellHeight: 17,
        cols: 80,
        rows: 24,
      );
      expect(col, 1);
      expect(row, 1);

      final (col2, row2) = ghosttyCellForPosition(
        dx: 100000,
        dy: 100000,
        cellWidth: 10,
        cellHeight: 17,
        cols: 80,
        rows: 24,
      );
      expect(col2, 80);
      expect(row2, 24);
    });

    test(
      'degenerate grid (zero cols/rows or cell size) never divides by zero',
      () {
        for (final bad in const [
          (0, 24, 10.0, 17.0),
          (80, 0, 10.0, 17.0),
          (80, 24, 0.0, 17.0),
          (80, 24, 10.0, 0.0),
        ]) {
          final (c, r, cw, ch) = bad;
          final (col, row) = ghosttyCellForPosition(
            dx: 50,
            dy: 50,
            cellWidth: cw,
            cellHeight: ch,
            cols: c,
            rows: r,
          );
          expect(col, greaterThanOrEqualTo(1));
          expect(row, greaterThanOrEqualTo(1));
        }
      },
    );

    test('explicit padding=0 maps from the overlay origin (no offset)', () {
      // With padding 0, the first cell starts at pixel 0.
      final (col, row) = ghosttyCellForPosition(
        dx: 0,
        dy: 0,
        cellWidth: 10,
        cellHeight: 17,
        cols: 80,
        rows: 24,
        padding: 0,
      );
      expect(col, 1);
      expect(row, 1);
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

  group('tap end-to-end: cell mapping feeds the click (#693/#699)', () {
    test('a tap pixel maps to a cell that produces the click reports', () {
      // 10px-wide / 17px-tall cells, 4px padding. Tap at (49, 55):
      // innerDx = 49-4 = 45 → floor(45/10)=4 → col 5 (1-based);
      // innerDy = 55-4 = 51 → floor(51/17)=3 → row 4 (1-based).
      final (col, row) = ghosttyCellForPosition(
        dx: 49,
        dy: 55,
        cellWidth: 10,
        cellHeight: 17,
        cols: 80,
        rows: 24,
      );
      expect((col, row), (5, 4));
      expect(ghosttyTapClickReports(col: col, row: row), [
        '\x1b[<0;5;4M',
        '\x1b[<0;5;4m',
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

    test('swipe LEFT past threshold → previous-window (wheel-up)', () {
      expect(
        ghosttyWindowSwitchForSwipe(-threshold, threshold),
        GhosttyWindowSwitch.previous,
      );
      expect(
        ghosttyWindowSwitchForSwipe(-200, threshold),
        GhosttyWindowSwitch.previous,
      );
    });

    test('swipe RIGHT past threshold → next-window (wheel-down)', () {
      expect(
        ghosttyWindowSwitchForSwipe(threshold, threshold),
        GhosttyWindowSwitch.next,
      );
      expect(
        ghosttyWindowSwitchForSwipe(200, threshold),
        GhosttyWindowSwitch.next,
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
        GhosttyWindowSwitch.next,
      );
      expect(
        ghosttyWindowSwitchForSwipe(-threshold, threshold),
        GhosttyWindowSwitch.previous,
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
    test(
      'swipe RIGHT emits one wheel-DOWN at the status row (next-window)',
      () {
        final decision = ghosttyWindowSwitchForSwipe(
          64,
          kGhosttyWindowSwitchThreshold,
        );
        expect(decision, GhosttyWindowSwitch.next);
        final (col, row) = ghosttyStatusRowCell(rows: 24);
        expect(ghosttySgrWheelDown(col: col, row: row), '\x1b[<65;1;24M');
      },
    );

    test('swipe LEFT emits one wheel-UP at the status row (prev-window)', () {
      final decision = ghosttyWindowSwitchForSwipe(
        -64,
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
