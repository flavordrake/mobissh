// #719 — Ghostty horizontal-swipe → tmux window-switch SMOKE TEST.
//
// The owner-mandated regression guard for the swipe→window-switch path, which
// has regressed repeatedly (#693 introduced it, #702/#708 reworked it, #719 it
// broke again). The earlier ghostty tests gate only the PURE helpers
// ([ghosttyAxisLock], [ghosttyWindowSwitchForSwipe], [ghosttyStatusRowCell],
// the SGR encoders). This test pumps the ACTUAL gesture router widget
// ([GhosttyPointerGestureRouter] — `RawGestureDetector` + callbacks, NO flterm
// native `.so` needed), simulates a REAL finger drag, and asserts the
// synthesised SGR wheel report `onMouseReport` receives lands at the EXPECTED
// status row — so a future regression in the drag→report wiring is caught
// headless in `scripts/native-fast-gate.sh`, not on-device.
//
// It also pins the #719 ROOT-CAUSE fix: the wheel must target the rows tmux
// ACTUALLY has (the last grid SENT via sendResize, [lastSentRows]), NOT the live
// local grid ([rows]). Device telemetry: the live grid grew 28→47 on a keyboard
// toggle but tmux was still on 28, so a wheel at the live status row (47) missed
// tmux's real status line (28) → no window switch. The desync test below
// constructs exactly that mismatch and asserts the wheel targets the LAST-SENT
// rows.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  // Parse the row out of an SGR-1006 wheel report `CSI < btn ; col ; row M`.
  // Returns null if the string isn't a wheel report. Used to assert the wheel
  // landed on the expected status row without coupling to col.
  int? wheelRow(String sgr) {
    final m = RegExp(r'^\x1b\[<(\d+);(\d+);(\d+)M$').firstMatch(sgr);
    if (m == null) return null;
    final btn = int.parse(m.group(1)!);
    if (btn != 64 && btn != 65) return null; // not a wheel up/down
    return int.parse(m.group(3)!);
  }

  int? wheelButton(String sgr) {
    final m = RegExp(r'^\x1b\[<(\d+);(\d+);(\d+)M$').firstMatch(sgr);
    if (m == null) return null;
    return int.parse(m.group(1)!);
  }

  // Pump the router under test, returning the list it sinks mouse reports into.
  // Defaults to ACTIVE (mouse mode on) so the gesture is routed, and a grid where
  // the live rows == lastSentRows unless overridden (the in-sync happy path).
  Future<List<String>> pumpRouter(
    WidgetTester tester, {
    bool active = true,
    int cols = 80,
    int rows = 24,
    int? lastSentCols,
    int? lastSentRows,
    TerminalScrollController? scrollController,
  }) async {
    final reports = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GhosttyPointerGestureRouter(
            active: active,
            scrollController: scrollController ?? TerminalScrollController(),
            cols: cols,
            rows: rows,
            lastSentCols: lastSentCols ?? cols,
            lastSentRows: lastSentRows ?? rows,
            cellWidth: 8,
            cellHeight: 16,
            mouseTrackingLabel: 'any',
            onTap: () {},
            onFocus: () {},
            onMouseReport: reports.add,
            onSelectionStart: (_, _) {},
            onSelectionExtend: (_, _) {},
            hasSelection: () => false,
            onSelectionClear: () {},
            urlAtCell: (_, _) => null,
            onUrlTap: (_) {},
            onUrlLongPress: (_, _) {},
          ),
        ),
      ),
    );
    return reports;
  }

  // #911 Part C: pump the router with control-mode gestures ON, returning the
  // window-switch directions and status-tap (col,totalCols) the router emits via
  // the REAL-command callbacks (instead of synthesised SGR). Also returns the SGR
  // sink so a test can assert NO SGR is forwarded under the flag.
  Future<
      ({
        List<bool> switches,
        List<(int, int)> statusTaps,
        List<String> sgr,
      })> pumpControlModeRouter(
    WidgetTester tester, {
    int cols = 80,
    int rows = 24,
  }) async {
    final switches = <bool>[];
    final statusTaps = <(int, int)>[];
    final sgr = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GhosttyPointerGestureRouter(
            active: true,
            scrollController: TerminalScrollController(),
            cols: cols,
            rows: rows,
            lastSentCols: cols,
            lastSentRows: rows,
            cellWidth: 8,
            cellHeight: 16,
            mouseTrackingLabel: 'any',
            onTap: () {},
            onFocus: () {},
            onMouseReport: sgr.add,
            onSelectionStart: (_, _) {},
            onSelectionExtend: (_, _) {},
            hasSelection: () => false,
            onSelectionClear: () {},
            urlAtCell: (_, _) => null,
            onUrlTap: (_) {},
            onUrlLongPress: (_, _) {},
            controlModeGestures: true,
            onWindowSwitch: ({required bool next}) => switches.add(next),
            onStatusTap: ({required int col, required int totalCols}) =>
                statusTaps.add((col, totalCols)),
          ),
        ),
      ),
    );
    return (switches: switches, statusTaps: statusTaps, sgr: sgr);
  }

  group('#719 horizontal swipe → window-switch wheel report (drag→report)', () {
    testWidgets('swipe RIGHT emits ONE wheel-DOWN at the status row', (
      tester,
    ) async {
      // rows=24, in sync with tmux → status row is 24 (bottom).
      final reports = await pumpRouter(tester, rows: 24);
      final center = tester.getCenter(find.byType(GhosttyPointerGestureRouter));
      // A clear horizontal drag well past the 32px window-switch threshold, with
      // ~zero vertical so axis-lock commits horizontal.
      await tester.dragFrom(center, const Offset(120, 0));
      await tester.pumpAndSettle();

      expect(
        reports,
        hasLength(1),
        reason: 'ONE discrete window step per swipe',
      );
      expect(
        wheelButton(reports.single),
        65,
        reason: 'swipe RIGHT → next-window → WheelDownStatus (btn 65)',
      );
      expect(
        wheelRow(reports.single),
        24,
        reason: 'wheel must land on the bottom status row (rows)',
      );
    });

    testWidgets('swipe LEFT emits ONE wheel-UP at the status row', (
      tester,
    ) async {
      final reports = await pumpRouter(tester, rows: 30);
      final center = tester.getCenter(find.byType(GhosttyPointerGestureRouter));
      await tester.dragFrom(center, const Offset(-120, 0));
      await tester.pumpAndSettle();

      expect(reports, hasLength(1));
      expect(
        wheelButton(reports.single),
        64,
        reason: 'swipe LEFT → previous-window → WheelUpStatus (btn 64)',
      );
      expect(wheelRow(reports.single), 30);
    });

    testWidgets('a sub-threshold horizontal nudge emits NO wheel report', (
      tester,
    ) async {
      final reports = await pumpRouter(tester);
      final center = tester.getCenter(find.byType(GhosttyPointerGestureRouter));
      // Past the axis-lock slop (12) so it commits horizontal, but under the
      // 32px window-switch threshold → committed-horizontal but no step.
      await tester.dragFrom(center, const Offset(20, 0));
      await tester.pumpAndSettle();
      expect(reports, isEmpty);
    });
  });

  group('#719 vertical swipe scrolls — axis-lock, NO wheel report', () {
    testWidgets('a clear vertical drag emits NO mouse report', (tester) async {
      // Vertical commit → only the local scroll path runs (a no-op here, since
      // the scroll controller has no attached Scrollable), and crucially NO SGR
      // window-switch wheel is forwarded to the remote. This is the axis-lock
      // guarantee: a scroll must never step a tmux window (#708/#719).
      final reports = await pumpRouter(tester);
      final center = tester.getCenter(find.byType(GhosttyPointerGestureRouter));
      await tester.dragFrom(center, const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(
        reports,
        isEmpty,
        reason: 'vertical = scroll, never a wheel report',
      );
    });

    testWidgets(
      'a vertical drag with horizontal jitter still does not switch',
      (tester) async {
        // The #708 regression half: a scroll with a few px of horizontal drift
        // must NOT trip a window-switch. dy dominates → locks vertical.
        final reports = await pumpRouter(tester);
        final center = tester.getCenter(
          find.byType(GhosttyPointerGestureRouter),
        );
        await tester.dragFrom(center, const Offset(20, -120));
        await tester.pumpAndSettle();
        expect(reports, isEmpty);
      },
    );
  });

  group('#911 control-mode gestures: REAL commands, NO synthesised SGR', () {
    testWidgets('swipe RIGHT → onWindowSwitch(next), no SGR forwarded', (
      tester,
    ) async {
      final r = await pumpControlModeRouter(tester);
      final center = tester.getCenter(find.byType(GhosttyPointerGestureRouter));
      await tester.dragFrom(center, const Offset(120, 0));
      await tester.pumpAndSettle();
      expect(r.switches, [true], reason: 'swipe RIGHT → next-window');
      expect(r.sgr, isEmpty, reason: 'control mode must not synthesise SGR');
    });

    testWidgets('swipe LEFT → onWindowSwitch(previous), no SGR forwarded', (
      tester,
    ) async {
      final r = await pumpControlModeRouter(tester);
      final center = tester.getCenter(find.byType(GhosttyPointerGestureRouter));
      await tester.dragFrom(center, const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(r.switches, [false], reason: 'swipe LEFT → previous-window');
      expect(r.sgr, isEmpty);
    });

    testWidgets('a tap on the STATUS ROW → onStatusTap(col,totalCols)', (
      tester,
    ) async {
      // 80x24 grid, cell 8x16 → the status row (row 24) is the bottom band.
      final r = await pumpControlModeRouter(tester, cols: 80, rows: 24);
      final box = tester.getRect(find.byType(GhosttyPointerGestureRouter));
      // Tap near the bottom (status row) at ~40% across → a real status tap.
      final tapPoint = Offset(box.left + box.width * 0.4, box.bottom - 4);
      await tester.tapAt(tapPoint);
      await tester.pumpAndSettle();
      expect(r.statusTaps, hasLength(1),
          reason: 'a status-row tap issues a select-window gesture');
      final (col, totalCols) = r.statusTaps.single;
      expect(totalCols, 80);
      expect(col, greaterThan(0));
      expect(col, lessThanOrEqualTo(80));
      expect(r.sgr, isEmpty, reason: 'no synthesised SGR click under the flag');
    });

    testWidgets('a tap ABOVE the status row does NOT issue a window gesture', (
      tester,
    ) async {
      final r = await pumpControlModeRouter(tester, cols: 80, rows: 24);
      final box = tester.getRect(find.byType(GhosttyPointerGestureRouter));
      // Tap near the TOP (a content row, not the status bar).
      await tester.tapAt(Offset(box.left + box.width * 0.4, box.top + 4));
      await tester.pumpAndSettle();
      expect(r.statusTaps, isEmpty,
          reason: 'only the status row switches windows');
      expect(r.sgr, isEmpty);
    });
  });

  group('#922 keyboard-aware grid → status-tap lands on tmux status row', () {
    testWidgets(
      'a status-tap maps to the LAST-SENT (keyboard-aware) status row',
      (tester) async {
        // #922 root: under the keyboard the visible box is short (~34 rows), but
        // flterm settled its grid back to the keyboard-DOWN size (57) and that's
        // what tmux had — so its status bar was at row 57, off-screen below the
        // keyboard. A tap on the visible bottom mapped to the middle of the
        // 57-row grid (a cursor move, no switch). The fix sends the KEYBOARD-AWARE
        // grid (via ghosttyGridForBox) so lastSentRows == the visible rows; the
        // status-tap (which targets lastSentRows, #719) then lands on tmux's real
        // status row. Here lastSentRows==rows==34 models the post-fix state: a tap
        // at the visible bottom issues a status tap at row 34, NOT a middle click.
        final r = await pumpControlModeRouter(tester, cols: 58, rows: 34);
        final box = tester.getRect(find.byType(GhosttyPointerGestureRouter));
        await tester.tapAt(Offset(box.left + box.width * 0.4, box.bottom - 4));
        await tester.pumpAndSettle();
        expect(r.statusTaps, hasLength(1),
            reason: 'a tap at the visible bottom hits the status row');
        final (col, totalCols) = r.statusTaps.single;
        expect(totalCols, 58);
        expect(col, greaterThan(0));
        expect(r.sgr, isEmpty);
      },
    );

    testWidgets(
      'ghosttyGridForBox(keyboard-up box) feeds a grid whose status row is the '
      'visible bottom',
      (tester) async {
        // Tie the helper to the router end to end: compute the grid for the SAME
        // box the router lays out in (keyboard UP), then pump the router at that
        // grid and assert a bottom tap hits the status row. This proves the
        // computed grid keeps tmux's status bar at the visible bottom.
        const cellW = 8.0;
        const cellH = 16.0;
        // A keyboard-reduced box. Use the router's full Scaffold body size: pump
        // first to read it, but we know the test surface — derive the grid from a
        // representative reduced height instead and assert the tap-row equality.
        final (cols, rows) = ghosttyGridForBox(
          boxWidth: 58 * cellW + 8,
          boxHeight: 34 * cellH + 8,
          cellWidth: cellW,
          cellHeight: cellH,
        );
        expect(cols, 58);
        expect(rows, 34);
        final r = await pumpControlModeRouter(tester, cols: cols, rows: rows);
        final box = tester.getRect(find.byType(GhosttyPointerGestureRouter));
        await tester.tapAt(Offset(box.left + box.width * 0.5, box.bottom - 2));
        await tester.pumpAndSettle();
        expect(r.statusTaps, hasLength(1),
            reason: 'the keyboard-aware grid puts the status row at the bottom');
      },
    );
  });

  group('#719 inactive overlay (no mouse mode) forwards no wheel', () {
    testWidgets('a horizontal swipe in a plain shell emits NO SGR', (
      tester,
    ) async {
      // active=false → translucent tap layer, no pan router; flterm handles its
      // own scroll. A swipe must NOT synthesise a window-switch wheel.
      final reports = await pumpRouter(tester, active: false);
      final center = tester.getCenter(find.byType(GhosttyPointerGestureRouter));
      await tester.dragFrom(center, const Offset(120, 0));
      await tester.pumpAndSettle();
      expect(reports, isEmpty);
    });
  });

  group('#719 REGRESSION: wheel targets tmux\'s last-sent rows, not live grid', () {
    testWidgets(
      'live grid grew (28→47) but tmux still on 28 → wheel lands on row 28',
      (tester) async {
        // The exact device-telemetry desync: the keyboard toggled so the LOCAL
        // grid grew to 47 (rows=47) and _rows would say 47, but the last resize
        // SENT to tmux was rows=28 (lastSentRows=28). Before the fix the wheel
        // fired at row 47 (live grid) and missed tmux's real status line (row 28)
        // → no window switch. The fix targets lastSentRows, so the wheel must
        // land on row 28 — tmux's ACTUAL status row.
        final reports = await pumpRouter(
          tester,
          rows: 47, // live grid after keyboard toggle
          lastSentRows: 28, // what tmux actually has
          lastSentCols: 80,
          cols: 80,
        );
        final center = tester.getCenter(
          find.byType(GhosttyPointerGestureRouter),
        );
        await tester.dragFrom(center, const Offset(120, 0));
        await tester.pumpAndSettle();

        expect(reports, hasLength(1));
        expect(
          wheelRow(reports.single),
          28,
          reason:
              'wheel must target tmux\'s last-sent status row (28), NOT the '
              'diverged live grid (47) — the #719 miss',
        );
        expect(wheelButton(reports.single), 65); // swipe RIGHT → next
      },
    );

    testWidgets(
      'falls back to the live rows only when nothing was ever sent (rows=0)',
      (tester) async {
        // Defensive: before the first resize lands lastSentRows is 0. The wheel
        // then falls back to the live grid so it still targets a real row, not 0.
        final reports = await pumpRouter(
          tester,
          rows: 24,
          lastSentRows: 0,
          lastSentCols: 0,
        );
        final center = tester.getCenter(
          find.byType(GhosttyPointerGestureRouter),
        );
        await tester.dragFrom(center, const Offset(-120, 0));
        await tester.pumpAndSettle();
        expect(reports, hasLength(1));
        expect(wheelRow(reports.single), 24); // fell back to live rows
      },
    );
  });
}
