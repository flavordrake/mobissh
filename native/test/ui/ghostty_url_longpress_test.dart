// #734 — Ghostty long-press URL → Copy/Open action-menu DECISION smoke test.
//
// #726 wired single-tap-to-copy on the ghostty (default) terminal, but the
// long-press → Copy/Open action menu (`showUrlActions` / url_action_overlay.dart,
// keys `url-action-menu`/`url-action-copy`/`url-action-open`) was only wired into
// the XTERM branch (`terminal_screen.dart` `_onTerminalLongPress`). Under the
// ghostty default a long-press on a URL did nothing — tap-copy but no Open menu.
//
// #734 wires it in: on a long-press the router hit-tests the press cell against
// the SAME detected URL ranges tap-copy uses (`urlAtCell`, #726). If the press
// lands ON a URL it fires `onUrlLongPress(match, anchor)` (the parent shows the
// `showUrlActions` overlay) and SUPPRESSES the #705/#706 selection for that
// gesture; if it lands OFF any URL the existing long-press SELECTION starts as
// today. URL hit-test WINS over selection; selection is otherwise unchanged.
//
// This pumps the ACTUAL gesture router widget (`GhosttyPointerGestureRouter` —
// `RawGestureDetector` + callbacks, NO flterm native `.so`), simulates a real
// long-press at a chosen cell, and asserts the routing decision. The off-URL case
// pins that #705/#706 selection still starts (no regression).

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

void main() {
  // #767: a single detected match occupying viewport cells (col 4..14) on row 2
  // (0-based). The detection now lives inside the terminal as a flterm
  // StructuredMatch; the router hit-tests via `urlAtCell` → controller.matchAt.
  // Here we stand in a StructuredMatch directly (no native .so) so the router
  // gesture-routing decision (#734) is still smoke-tested headless.
  const urlMatch = StructuredMatch(
    patternId: 'url',
    payload: 'https://example.com',
    ranges: [
      HighlightRange(startRow: 2, startCol: 4, endRow: 2, endCol: 15),
    ],
  );

  // Records of each routing callback the router fires, so a test can assert which
  // path a long-press took.
  late List<StructuredMatch> urlLongPresses;
  late List<(int, int)> selectionStarts;
  late List<(int, int)> selectionExtends;

  // Pump the router with the single [urlMatch] detected. cellWidth=8/cellHeight=16
  // + kGhosttyTerminalPadding(4) so a global tap at (px,py) maps to cell
  // ((px-4)/8, (py-4)/16) (1-based, then the URL hit-test subtracts 1 back to
  // 0-based — matching the tap-copy convention).
  Future<void> pumpRouter(WidgetTester tester) async {
    urlLongPresses = [];
    selectionStarts = [];
    selectionExtends = [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 400,
              child: GhosttyPointerGestureRouter(
                active: true,
                scrollController: TerminalScrollController(),
                cols: 80,
                rows: 24,
                lastSentCols: 80,
                lastSentRows: 24,
                cellWidth: 8,
                cellHeight: 16,
                mouseTrackingLabel: 'any',
                onTap: () {},
                onFocus: () {},
                onMouseReport: (_) {},
                onSelectionStart: (c, r) => selectionStarts.add((c, r)),
                onSelectionExtend: (c, r) => selectionExtends.add((c, r)),
                hasSelection: () => false,
                onSelectionClear: () {},
                urlAtCell: (col, row) =>
                    urlMatch.contains(row, col) ? urlMatch : null,
                onUrlTap: (_) {},
                onUrlLongPress: (m, _) => urlLongPresses.add(m),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Synthesise a stationary long-press (down, hold past the recogniser timeout,
  // up) at [global] without any drag.
  Future<void> longPressAt(WidgetTester tester, Offset global) async {
    final gesture = await tester.startGesture(global);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  group('#734 long-press ON a URL → action menu, NOT selection', () {
    testWidgets('fires onUrlLongPress with the matched URL', (tester) async {
      await pumpRouter(tester);
      // Cell on the URL: row 2 (0-based) → py in [4+2*16, 4+3*16) = [36,52);
      // col 6 (0-based, inside 4..14) → px in [4+6*8, 4+7*8) = [52,60).
      await longPressAt(tester, const Offset(54, 44));

      expect(
        urlLongPresses,
        hasLength(1),
        reason: 'a long-press on a detected URL shows the Copy/Open menu',
      );
      expect(urlLongPresses.single.payload, 'https://example.com');
    });

    testWidgets('does NOT start a selection (URL hit-test wins)', (
      tester,
    ) async {
      await pumpRouter(tester);
      await longPressAt(tester, const Offset(54, 44));

      expect(
        selectionStarts,
        isEmpty,
        reason: 'URL hit-test WINS over selection on long-press',
      );
      expect(selectionExtends, isEmpty);
    });
  });

  group('#734 long-press OFF any URL → selection unchanged (#705/#706)', () {
    testWidgets('starts a selection and fires NO onUrlLongPress', (
      tester,
    ) async {
      await pumpRouter(tester);
      // Cell OFF the URL: row 5 (0-based) → py in [4+5*16, 4+6*16) = [84,100);
      // col 6 → px [52,60). Row 5 has no URL.
      await longPressAt(tester, const Offset(54, 92));

      expect(urlLongPresses, isEmpty, reason: 'off a URL there is no menu');
      expect(
        selectionStarts,
        hasLength(1),
        reason: 'off a URL the existing #705/#706 selection starts as today',
      );
    });
  });

  group('#734 pure decision helper', () {
    test('ghosttyLongPressShowsUrlMenu true iff a URL is at the cell', () {
      expect(ghosttyLongPressShowsUrlMenu(urlMatch), isTrue);
      expect(ghosttyLongPressShowsUrlMenu(null), isFalse);
    });
  });

  group('#734 drag after a URL long-press does not extend a selection', () {
    testWidgets('a long-press-drag on a URL stays on the menu (no extend)', (
      tester,
    ) async {
      await pumpRouter(tester);
      // Long-press ON the URL, then drag — the menu owns the gesture, so no
      // selection extend should fire (the #705 drag-select is suppressed).
      final gesture = await tester.startGesture(const Offset(54, 44));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(urlLongPresses, hasLength(1));
      expect(selectionStarts, isEmpty);
      expect(selectionExtends, isEmpty);
    });
  });
}
