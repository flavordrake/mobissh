// #723 — Ghostty resize correctness: flterm's ACTUAL grid is the single source
// of truth for every gesture decision.
//
// Root cause (live-tmux confirmed): the gesture router had TWO grid notions —
// the LIVE `controller.onResize` grid (`cols`/`rows`) and the grid LAST SENT to
// the PTY (`lastSentCols`/`lastSentRows`, = what tmux actually has). They
// normally agree, but a transient onResize (or the overlay being the FULL Stack
// box, bigger than flterm's grid-sized render box) can leave the live grid AHEAD
// of tmux. The device repro logged `grid=58x56` and fired the window-switch
// wheel at row 56, while the LIVE tmux client was only ever 55×28 ↔ 55×47 — so
// the wheel missed tmux's status line and swipe-left scrolled instead of
// switching windows. The cell CLAMP had the same flaw (a touch could map past
// tmux's real grid).
//
// The fix makes the LAST-SENT grid the single source of truth for BOTH the
// window-switch wheel row (already #719) AND the cell clamp. These tests pump the
// real [GhosttyPointerGestureRouter] with live ≠ last-sent and assert every
// grid-dependent output uses the last-sent (flterm's actual) grid. The cell
// SIZE (#699 `ghosttyMeasureCellSize`) is unchanged — the divergence was the GRID
// notion, not the per-cell pixel size.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/gesture_trace.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  // Parse the (col,row) out of an SGR-1006 report `CSI < btn ; col ; row M/m`.
  (int btn, int col, int row)? sgrParts(String sgr) {
    final m = RegExp(r'^\x1b\[<(\d+);(\d+);(\d+)[Mm]$').firstMatch(sgr);
    if (m == null) return null;
    return (
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
  }

  Future<List<String>> pumpRouter(
    WidgetTester tester, {
    bool active = true,
    int cols = 80,
    int rows = 24,
    int? lastSentCols,
    int? lastSentRows,
    double cellWidth = 8,
    double cellHeight = 16,
    bool Function()? hasSelection,
    void Function(int col, int row)? onSelectionStart,
  }) async {
    final reports = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GhosttyPointerGestureRouter(
            active: active,
            scrollController: TerminalScrollController(),
            cols: cols,
            rows: rows,
            lastSentCols: lastSentCols ?? cols,
            lastSentRows: lastSentRows ?? rows,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            mouseTrackingLabel: 'any',
            onTap: () {},
            onFocus: () {},
            onMouseReport: reports.add,
            onSelectionStart: onSelectionStart ?? (_, _) {},
            onSelectionExtend: (_, _) {},
            hasSelection: hasSelection ?? () => false,
            onSelectionClear: () {},
            urlAtCell: (_, _) => null,
            onUrlTap: (_) {},
          ),
        ),
      ),
    );
    return reports;
  }

  group('#723 last-sent grid is the single source of truth — WHEEL', () {
    testWidgets(
      'live grid 56 rows but tmux has 47 → wheel targets row 47, not 56',
      (tester) async {
        // The exact device-log shape: live onResize grew the grid (rows=56) but
        // the grid SENT to tmux is 47. A wheel at the live status row (56) misses
        // tmux's status line (47). The fix targets the last-sent rows.
        final reports = await pumpRouter(
          tester,
          rows: 56, // live (overlay/onResize) grid
          lastSentRows: 47, // what tmux actually has
          cols: 58,
          lastSentCols: 55,
        );
        final center = tester.getCenter(
          find.byType(GhosttyPointerGestureRouter),
        );
        await tester.dragFrom(center, const Offset(120, 0));
        await tester.pumpAndSettle();

        expect(reports, hasLength(1));
        final parts = sgrParts(reports.single)!;
        expect(parts.$1, 65, reason: 'swipe RIGHT → next-window → WheelDown');
        expect(
          parts.$3,
          47,
          reason: 'wheel must land on tmux\'s ACTUAL status row (47), not 56',
        );
      },
    );
  });

  group('#723 last-sent grid is the single source of truth — CELL CLAMP', () {
    testWidgets(
      'a tap past tmux\'s last row clamps to it (47), not the larger live grid (56)',
      (tester) async {
        // Small cells (5px wide, 10px tall) so a tap at the far bottom-right of
        // the 800x600 test surface produces a RAW cell index past BOTH grids
        // (raw row ≈ floor((600-1-4)/10)+1 = 60, raw col ≈ floor((800-1-4)/5)+1 =
        // 160). The clamp must land it on tmux's ACTUAL grid: row 47 / col 55
        // (last-sent), NOT the larger live grid (row 56 / col 58) that tmux
        // doesn't have. mouse mode ON → the tap forwards an SGR click we can read.
        final reports = await pumpRouter(
          tester,
          rows: 56, // live (overlay/onResize) grid
          lastSentRows: 47, // what tmux actually has
          cols: 58,
          lastSentCols: 55,
          cellWidth: 5,
          cellHeight: 10,
        );
        final box = tester.getRect(find.byType(GhosttyPointerGestureRouter));
        await tester.tapAt(box.bottomRight - const Offset(1, 1));
        await tester.pumpAndSettle();

        // A tap CLICK forwards press THEN release (#693) → two reports at the
        // SAME cell. Read the press (first); both carry the clamped cell.
        expect(reports, hasLength(2), reason: 'tap → SGR press + release');
        final parts = sgrParts(reports.first)!;
        expect(
          parts.$3,
          47,
          reason: 'tap row clamps to tmux\'s real last row (47), not live 56',
        );
        expect(
          parts.$2,
          55,
          reason: 'tap col clamps to tmux\'s real last col (55), not live 58',
        );
      },
    );
  });

  group(
    '#723 telemetry: gesture line carries live grid AND last-sent grid',
    () {
      test('formatGestureEvent emits grid= (live) and sent= (last-sent)', () {
        final line = formatGestureEvent(
          type: 'swipe-h',
          dx: 120,
          dy: 0,
          width: 800,
          height: 900,
          cols: 58, // live onResize grid
          rows: 56,
          sentCols: 55, // grid last sent to PTY (tmux)
          sentRows: 47,
          col: 1,
          row: 47,
          sgr: '\x1b[<65;1;47M',
          mouseTracking: 'buttonEvent',
          handledBy: 'overlay',
        );
        expect(line, contains('grid=58x56'), reason: 'live onResize grid');
        expect(line, contains('sent=55x47'), reason: 'grid tmux actually has');
      });

      test(
        'sent defaults to the live grid when not supplied (in-sync line)',
        () {
          final line = formatGestureEvent(
            type: 'tap',
            dx: 1,
            dy: 1,
            width: 800,
            height: 600,
            cols: 80,
            rows: 24,
            mouseTracking: 'none',
            handledBy: 'flterm',
          );
          expect(line, contains('grid=80x24'));
          expect(line, contains('sent=80x24'));
        },
      );
    },
  );
}
