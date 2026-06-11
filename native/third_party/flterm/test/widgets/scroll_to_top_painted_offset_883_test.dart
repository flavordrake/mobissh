// #883 (cycle 2) — the ON-EMULATOR mechanism behind "matchAt on the URL cell
// after scroll did not resolve it", pinned headless.
//
// `TerminalControllerImpl.scrollToTop()` used to set the FFI scrollbar to 0
// (`terminal.scrollToTop()`) BEFORE jumping the ScrollController. The render
// box's `_onScroll` derives its scroll delta as
// `targetOffset - scrollbar.offset`; with the FFI offset already 0 the delta
// was 0 and `_onScroll` returned WITHOUT marking the frame dirty. The frame
// never re-synced, so:
//   - the glyphs kept showing the BOTTOM of scrollback (stale paint), and
//   - `reportPaintedViewportOffset(0)` never fired — [paintedViewportOffset]
//     stayed at the bottom value indefinitely (no further output → nothing
//     else refreshes the frame's offset).
// [matchAt]/[highlightAt] map viewport→absolute via the PAINTED offset so
// hit-test and paint share one geometry source (#863); with the painted
// offset stale at ~bottom, a tap on the URL now visible at the TOP of
// scrollback resolved to a wrong absolute row → null. The detection anchor
// itself was alive the whole time (instrumented on-emulator: anchors carried
// the URL payload, scrollbar.offset == 0, paintedViewportOffset == 195) —
// hypothesis (b), not a prune eviction.
//
// The fix reorders scrollToTop: jump the ScrollController FIRST (while the
// FFI scrollbar still holds the old offset) so `_onScroll` sees the real
// delta → `scrollViewport` + frame-dirty → the next paint syncs and reports
// offset 0; `terminal.scrollToTop()` stays as the detached/headless backstop.
//
// RED on the pre-fix order: paintedViewportOffset stays at the bottom value
// and matchAt returns null. GREEN with the reorder.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const url = 'https://example.com/some/path/page';

  Widget wrapInApp(TerminalController controller) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 480,
          child: TerminalView(controller: controller),
        ),
      ),
    );
  }

  testWidgets(
    'programmatic scrollToTop repaints the frame: the painted viewport offset '
    'reaches 0, the anchor survives the pure viewport scroll, and matchAt '
    'resolves the URL at the top of scrollback (#883)',
    (tester) async {
      final controller = TerminalController();
      addTearDown(controller.dispose);
      controller.registerTextPattern(TextPattern.url());

      await tester.pumpWidget(wrapInApp(controller));
      await tester.pump();

      void write(String s) {
        controller.write(Uint8List.fromList(utf8.encode(s)));
      }

      // Print the URL, then push it to the very top of scrollback. Nowhere
      // near the scrollback cap — no eviction, no row shift: the ONLY
      // mechanism in play is the pure viewport scroll. Filler lines are
      // LONGER than the URL row so the scanner's inferred-wrap-col heuristic
      // never width-joins the URL with its neighbour (same trick as
      // scrollback_eviction_anchor_883_test.dart).
      write('$url\r\n');
      for (var i = 0; i < 200; i++) {
        write('f${i.toString().padLeft(5, '0')} ${'x' * 30}\r\n');
      }
      // Let layout stick-to-bottom, the ~120ms detection debounce, and the
      // ~140ms scroll-settle timer all run, then paint a settled frame.
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(
        controller.scrollbackRows,
        greaterThan(0),
        reason: 'precondition: the output filled scrollback',
      );
      expect(
        controller.anchors.any((a) => a.payload == url),
        isTrue,
        reason: 'precondition: the URL is detected in scrollback',
      );
      expect(
        controller.paintedViewportOffset,
        greaterThan(0),
        reason: 'precondition: the frame painted at the BOTTOM of scrollback '
            '(stick-to-bottom), so the painted offset is non-zero',
      );

      controller.scrollToTop();
      // One frame for the repaint the scroll MUST trigger, then settle the
      // detection debounce + scroll-settle timers.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(controller.scrollbar.offset, 0,
          reason: 'scrollToTop moved the live scrollbar to the top');

      // The anchor must survive a PURE viewport scroll — no content changed,
      // so the synchronous prune has nothing to evict (hypothesis (a) ruled
      // out and pinned).
      expect(
        controller.anchors.any((a) => a.payload == url),
        isTrue,
        reason: 'a pure viewport scroll to top must not evict the anchor',
      );

      // THE #883 CYCLE-2 RED ASSERTION: the frame must have repainted at the
      // top — pre-fix the delta-0 early return left the painted offset stale
      // at the bottom value, so hit-tests resolved a wrong absolute row.
      expect(
        controller.paintedViewportOffset,
        0,
        reason: 'scrollToTop must repaint the frame so the painted viewport '
            'offset reaches 0 — a stale painted offset breaks every '
            'painted-offset hit-test (matchAt/highlightAt, #863)',
      );

      // And the user-visible behaviour: hit-testing the URL cell (viewport
      // row = absolute row - offset = absolute row) resolves the match.
      final range =
          controller.highlights.firstWhere((r) => r.payload == url);
      final viewRow = range.startRow - controller.scrollbar.offset;
      final match = controller.matchAt(row: viewRow, col: range.startCol);
      expect(
        match?.payload,
        url,
        reason: 'matchAt on the URL cell after scrollToTop must resolve it',
      );
    },
  );
}
