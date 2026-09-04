// #881 — telemetry: a plain tap on the INACTIVE gesture overlay (mouse
// tracking `none`) must land in the gesture log.
//
// Device report (2026-09-04, "bad tmux mode"): after a background
// auto-reconnect the local mouse-tracking state diverged to `none`, the overlay
// went inactive, and every tap fell through to flterm untraced. The gesture log
// showed nothing while `[ui.gw] send input` bursts (flterm's alternate-screen
// scroll fallback emitting cursor keys) filled the connect ring. Without a trace
// line the report could not even prove the overlay WAS inactive. This pins that
// an inactive plain tap emits a `tap-passthrough` entry attributed to `flterm`
// (the pointer really does fall through) carrying the mouse-tracking label.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/gesture_trace.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  setUp(clearGestureLog);

  Future<int> pumpInactiveRouter(WidgetTester tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GhosttyPointerGestureRouter(
            active: false,
            scrollController: TerminalScrollController(),
            cols: 80,
            rows: 24,
            lastSentCols: 80,
            lastSentRows: 24,
            cellWidth: 8,
            cellHeight: 16,
            mouseTrackingLabel: 'none',
            onTap: () => taps++,
            onFocus: () {},
            onMouseReport: (_) {},
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
    final center = tester.getCenter(find.byType(GhosttyPointerGestureRouter));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    return taps;
  }

  testWidgets(
    '#881 inactive overlay plain tap → gesture log entry attributed to flterm',
    (tester) async {
      final taps = await pumpInactiveRouter(tester);

      expect(taps, 1, reason: 'the tap still raises the keyboard via onTap');
      final log = gestureLogSnapshot();
      final entry = log.where((l) => l.contains('tap-passthrough')).toList();
      expect(entry, hasLength(1), reason: 'log: $log');
      expect(entry.single, contains('mouse=none'));
      expect(
        entry.single,
        contains('by=flterm'),
        reason: 'the pointer falls through to flterm — attribute it honestly',
      );
    },
  );
}
