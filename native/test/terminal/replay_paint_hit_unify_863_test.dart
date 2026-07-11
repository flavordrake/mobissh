@Tags(['ffi'])
library;

// INVARIANT (#863): the URL PAINT geometry and the TAP HIT-TEST geometry must
// AGREE. Two device reports (0.1.10+53) shared one root — the highlight bubble
// PAINTS its anchor rects against the controller's PAINTED viewport offset
// (`anchorRects` -> `AnchorGeometry.rectsFor`: `viewRow = absRow -
// paintedViewportOffset`), but `matchAt` (the tap hit-test) mapped the tapped
// viewport row to absolute via the LIVE `scrollbar.offset`. When those offsets
// diverged (during/after a tmux-redraw scroll, #803) the bubble drew at row N
// while the tappable cell sat at row N+/-1 -> the tap fell through to selection
// instead of copy/open, and the highlight looked a line off.
//
// THE FIX (unify on ONE geometry source): `matchAt`/`highlightAt` now map
// viewport->absolute via `paintedViewportOffset` — the SAME offset the painter
// uses. So a hit-test at the CENTER (and corners) of any PAINTED URL rect must
// resolve to THAT match, even under a forced live!=painted offset skew.
//
// This is the #791 WIDGET/PIXEL replay tier: it mounts the REAL flterm
// `TerminalView` (so the render box paints + reports its painted offset to the
// controller), replays a REAL captured wrapped-URL grid, and asserts the
// paint==hit invariant — at painted offset 0, with a forced live!=painted skew
// (the exact #863 frame-skew condition), and on a non-URL row. The byte stream
// IS the real grid; the round-trip catches the divergence the device reports
// describe with no device.

import 'package:flutter/material.dart';
import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart' show lfToCrlf;
import 'replay_url_detection_test.dart' show loadCast;

// The owner's REAL 55-col tmux capture: a plain-text URL the Claude TUI wraps at
// the content width into TWO physical rows (the +22..+28 saga grid). Exercises
// the wrapped multi-row URL case the #863 spec calls out.
const _kFixture = 'test/fixtures/replay/claude_wrapped_url_55col.cast.json';
const _kFullUrl = 'https://mobissh.tailbe5094.ts.net/'
    'mobissh-native-20260605T200823+0000.apk';

const double _kPadding = 4.0;

Future<TerminalController> _replayMounted(WidgetTester tester) async {
  final cast = loadCast(_kFixture);
  final controller = TerminalController(
    config: TerminalConfig(cols: cast.cols, rows: cast.rows),
  );
  controller.registerTextPattern(TextPattern.url());
  for (final chunk in cast.chunks) {
    // capture-pane separates visual rows with bare LF; map to CRLF (idempotent)
    // so each row returns to column 0 — mirrors `replayCast`.
    controller.write(lfToCrlf(chunk));
  }
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: TerminalView(
                controller: controller,
                autofocus: false,
                theme: TerminalTheme.dark().copyWith(fontSize: 14),
                padding: const EdgeInsets.all(_kPadding),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  // Let the render box paint + report its painted offset, and let detection
  // settle (debounced ~120ms).
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  return controller;
}

/// The detected wrapped-URL anchor (one anchor spanning both physical rows) —
/// the PAINT source whose per-row [ranges] feed `anchorRects`.
StructuredAnchor _urlAnchor(TerminalController controller) {
  final hits = controller.anchors.where((a) => a.payload == _kFullUrl).toList();
  expect(
    hits,
    hasLength(1),
    reason: 'the wrapped URL must be ONE detected anchor (the paint source)',
  );
  return hits.single;
}

/// Resolve the live cell size from a single painted row rect: its height IS one
/// cell height, and its width covers `(bottomCol-topCol)` cells of that row's
/// range.
Size _cellSizeFor(Rect rect, HighlightRange range) {
  final cols = range.bottomCol - range.topCol;
  return Size(rect.width / cols, rect.height);
}

/// Convert a painted point to the VIEWPORT (row, col) the gesture router would
/// compute (mirrors `ghosttyCellForPosition`: subtract the grid padding, divide
/// by the live cell size, floor). `anchorRects` returns rects in the grid's
/// padded LOCAL space, which is the same space `details.localPosition` is in.
(int row, int col) _viewportCellAt(Offset local, Size cell) {
  final col = ((local.dx - _kPadding) / cell.width).floor();
  final row = ((local.dy - _kPadding) / cell.height).floor();
  return (row, col);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('#863 — URL paint geometry and tap hit-test agree', () {
    testWidgets(
      'a hit-test at the CENTER + CORNERS of every PAINTED URL rect resolves to '
      'THAT match (painted offset 0, wrapped multi-row URL)',
      (tester) async {
        final controller = await _replayMounted(tester);
        addTearDown(controller.dispose);

        final anchor = _urlAnchor(controller);
        // The wrapped URL spans >= 2 rows — the multi-row case the spec requires.
        final spannedRows = {for (final r in anchor.ranges) r.topRow};
        expect(spannedRows.length, greaterThanOrEqualTo(2),
            reason: 'the captured URL wraps across rows (multi-row coverage)');

        var checkedCells = 0;
        for (final range in anchor.ranges) {
          final rects = controller.anchorRects(range);
          for (final rect in rects) {
            final cell = _cellSizeFor(rect, range);
            expect(cell.width, greaterThan(0));
            final cols = (rect.width / cell.width).round();
            // Sample the center of EVERY painted cell in this rect (left edge,
            // right edge, and middle are all covered as cols grows). A tap on
            // ANY painted cell of the URL must resolve to the URL match.
            for (var i = 0; i < cols; i++) {
              final p = Offset(
                rect.left + (i + 0.5) * cell.width,
                rect.center.dy,
              );
              final (row, col) = _viewportCellAt(p, cell);
              final hit = controller.matchAt(row: row, col: col);
              expect(
                hit?.payload,
                _kFullUrl,
                reason: 'tap at painted cell $i point $p -> viewport ($row,$col) '
                    'must resolve the painted URL (paint==hit invariant #863)',
              );
              checkedCells++;
            }
          }
        }
        expect(checkedCells, greaterThan(0),
            reason: 'the URL must paint at least one on-screen cell to test');
      },
    );

    testWidgets(
      'a viewport row NOT covered by the painted URL does not resolve the URL '
      '(no false-positive hit off the painted region)',
      (tester) async {
        final controller = await _replayMounted(tester);
        addTearDown(controller.dispose);

        final anchor = _urlAnchor(controller);
        // The viewport rows the URL paints on.
        final urlViewRows = <int>{};
        for (final range in anchor.ranges) {
          for (final rect in controller.anchorRects(range)) {
            final cell = _cellSizeFor(rect, range);
            final (row, _) = _viewportCellAt(rect.center, cell);
            urlViewRows.add(row);
          }
        }
        expect(urlViewRows, isNotEmpty,
            reason: 'the URL paints on at least one viewport row');

        var checkedEmpty = 0;
        final cast = loadCast(_kFixture);
        for (var row = 0; row < cast.rows && checkedEmpty < 5; row++) {
          if (urlViewRows.contains(row)) continue;
          final hit = controller.matchAt(row: row, col: 0);
          expect(hit?.payload, isNot(_kFullUrl),
              reason: 'a non-URL viewport row must not resolve the URL (#863)');
          checkedEmpty++;
        }
        expect(checkedEmpty, greaterThan(0));
      },
    );

    testWidgets(
      'matchAt follows the PAINTED offset, not the live scrollbar offset — under '
      'a forced live!=painted skew (the #863 frame-skew) a tap on the PAINTED '
      'URL rect still resolves the URL',
      (tester) async {
        final controller = await _replayMounted(tester);
        addTearDown(controller.dispose);

        // At rest the render box has painted, so painted == live (== 0 here).
        final painted = controller.paintedViewportOffset;
        final anchor = _urlAnchor(controller);

        // FORCE the divergence: report a STALE painted offset one row off the
        // live one — the exact #803/#863 condition where the painted glyphs lag
        // the live `scrollbar.offset` by a frame. Skew DOWN by one row
        // (painted-1) so the top-row URL's painted rect shifts down a row and
        // stays on screen (`anchorRects`: `viewRow = absRow - (painted-1)`).
        // Both the paint geometry (`anchorRects`) and the hit-test (`matchAt`)
        // now read this SAME (forced) painted offset, so the rect the bubble
        // draws and the cell the tap maps to stay in lockstep — we re-derive the
        // painted rect's viewport cell and confirm the tap still resolves.
        final skewed = painted - 1;
        controller.reportPaintedViewportOffset(skewed);
        await tester.pump(); // flush the post-frame notify
        expect(controller.paintedViewportOffset, skewed,
            reason: 'the painted offset is now skewed from the live offset');

        var checked = 0;
        for (final range in anchor.ranges) {
          for (final rect in controller.anchorRects(range)) {
            final cell = _cellSizeFor(rect, range);
            final (row, col) = _viewportCellAt(rect.center, cell);
            final hit = controller.matchAt(row: row, col: col);
            expect(hit?.payload, _kFullUrl,
                reason: 'SKEW: tap at the painted rect center -> ($row,$col) '
                    'still resolves the URL — matchAt consumes the painted '
                    'offset, so paint and hit-test cannot drift apart (#863)');
            checked++;
          }
        }
        expect(checked, greaterThan(0),
            reason: 'the URL still paints rects at the skewed offset');

        // Drain the #812 scroll-settle timer that reportPaintedViewportOffset
        // armed, so no timer is pending when the widget tree is torn down.
        // #1062: settling now re-shows the detection wash via a controller
        // notify, which repaints and reports the REAL painted offset — under
        // this SYNTHETIC skew (paintedViewportOffset was forced to a value the
        // render box never painted) that differs and re-arms one more settle
        // cycle before it converges (the real painted offset holds still). Pump
        // a few settle windows so the scroll state comes fully to rest.
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
      },
    );
  });
}
