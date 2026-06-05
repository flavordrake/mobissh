import 'dart:ui';

import 'package:flterm/src/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A simple square-ish cell so rects are easy to reason about.
  const metrics = CellMetrics(cellWidth: 10, cellHeight: 20, baseline: 16);
  const cols = 80;
  const viewportRows = 24;

  group('AnchorGeometry.rectsFor — single-row range', () {
    // A URL on absolute row 5, cols [4, 9): "see https://x" style.
    const range = HighlightRange(
      startRow: 5,
      startCol: 4,
      endRow: 5,
      endCol: 9,
      payload: 'https://x',
    );

    test('maps the range to one viewport-local rect at offset 0', () {
      final rects = AnchorGeometry.rectsFor(
        range,
        metrics: metrics,
        viewportOffset: 0,
        cols: cols,
        viewportRows: viewportRows,
      );
      expect(rects, hasLength(1));
      // viewRow == absRow - offset == 5; left = 4*10, width = (9-4)*10.
      expect(rects.single, const Rect.fromLTWH(40, 100, 50, 20));
    });

    test('rects MOVE up as the viewport scrolls down (offset grows)', () {
      final atRest = AnchorGeometry.rectsFor(
        range,
        metrics: metrics,
        viewportOffset: 0,
        cols: cols,
        viewportRows: viewportRows,
      ).single;
      final scrolled = AnchorGeometry.rectsFor(
        range,
        metrics: metrics,
        viewportOffset: 3, // three rows scrolled into history above
        cols: cols,
        viewportRows: viewportRows,
      ).single;
      // Same content, three rows higher on screen: top drops by 3 * cellHeight.
      expect(scrolled.top, atRest.top - 3 * 20);
      expect(scrolled.left, atRest.left);
      expect(scrolled.width, atRest.width);
      expect(scrolled.height, atRest.height);
    });

    test('applies the padding origin', () {
      final rects = AnchorGeometry.rectsFor(
        range,
        metrics: metrics,
        viewportOffset: 0,
        cols: cols,
        viewportRows: viewportRows,
        origin: const Offset(4, 4),
      );
      expect(rects.single, const Rect.fromLTWH(44, 104, 50, 20));
    });

    test('returns EMPTY when the range scrolls above the viewport', () {
      // offset 6 puts absolute row 5 at viewRow -1 (off the top).
      final rects = AnchorGeometry.rectsFor(
        range,
        metrics: metrics,
        viewportOffset: 6,
        cols: cols,
        viewportRows: viewportRows,
      );
      expect(rects, isEmpty);
    });

    test('returns EMPTY when the range is below the viewport', () {
      // A range far down; with offset 0 and only 24 rows, row 5 is visible,
      // but a row at 30 is not.
      const lowRange = HighlightRange(
        startRow: 30,
        startCol: 0,
        endRow: 30,
        endCol: 4,
      );
      final rects = AnchorGeometry.rectsFor(
        lowRange,
        metrics: metrics,
        viewportOffset: 0,
        cols: cols,
        viewportRows: viewportRows,
      );
      expect(rects, isEmpty);
    });
  });

  group('AnchorGeometry.rectsFor — wrapped (multi-row) range', () {
    // The scanner emits ONE HighlightRange PER row for a wrapped match, so a
    // wrapped anchor is two ranges. rectsFor on each yields its own rect; the
    // decorator joins them. But rectsFor must ALSO correctly handle a single
    // multi-row range (top + bottom partial, middle full) for robustness.
    test('a true multi-row range yields one rect per visible row', () {
      const multi = HighlightRange(
        startRow: 4,
        startCol: 70, // tail of row 4
        endRow: 6,
        endCol: 12, // head of row 6
        payload: 'wrapped',
      );
      final rects = AnchorGeometry.rectsFor(
        multi,
        metrics: metrics,
        viewportOffset: 0,
        cols: cols,
        viewportRows: viewportRows,
      );
      expect(rects, hasLength(3));
      // Row 4: from col 70 to end (cols).
      expect(rects[0], const Rect.fromLTWH(700, 80, (80 - 70) * 10.0, 20));
      // Row 5: full width.
      expect(rects[1], const Rect.fromLTWH(0, 100, 80 * 10.0, 20));
      // Row 6: from 0 to col 12.
      expect(rects[2], const Rect.fromLTWH(0, 120, 12 * 10.0, 20));
    });

    test('only the visible portion of a partially-scrolled wrapped range', () {
      const multi = HighlightRange(
        startRow: 0,
        startCol: 60,
        endRow: 2,
        endCol: 8,
      );
      // offset 1 hides absolute row 0 (viewRow -1); rows 1 and 2 remain.
      final rects = AnchorGeometry.rectsFor(
        multi,
        metrics: metrics,
        viewportOffset: 1,
        cols: cols,
        viewportRows: viewportRows,
      );
      expect(rects, hasLength(2));
      // Row 1 (viewRow 0): full width (middle row).
      expect(rects[0], const Rect.fromLTWH(0, 0, 80 * 10.0, 20));
      // Row 2 (viewRow 1): 0..8.
      expect(rects[1], const Rect.fromLTWH(0, 20, 8 * 10.0, 20));
    });
  });

  group('AnchorGeometry guards', () {
    const range = HighlightRange(startRow: 0, startCol: 0, endRow: 0, endCol: 4);

    test('returns empty for non-positive cell metrics', () {
      const zero = CellMetrics(cellWidth: 0, cellHeight: 0, baseline: 0);
      expect(
        AnchorGeometry.rectsFor(
          range,
          metrics: zero,
          viewportOffset: 0,
          cols: cols,
          viewportRows: viewportRows,
        ),
        isEmpty,
      );
    });

    test('returns empty for non-positive grid dimensions', () {
      expect(
        AnchorGeometry.rectsFor(
          range,
          metrics: metrics,
          viewportOffset: 0,
          cols: 0,
          viewportRows: viewportRows,
        ),
        isEmpty,
      );
    });
  });

  group('AnchorGeometry.gutterRowFor', () {
    const range = HighlightRange(
      startRow: 5,
      startCol: 4,
      endRow: 5,
      endCol: 9,
    );

    test('returns the top visible viewport row', () {
      expect(
        AnchorGeometry.gutterRowFor(range, viewportOffset: 0, viewportRows: 24),
        5,
      );
      expect(
        AnchorGeometry.gutterRowFor(range, viewportOffset: 3, viewportRows: 24),
        2,
      );
    });

    test('returns the first on-screen row of a partly-scrolled range', () {
      const multi = HighlightRange(
        startRow: 0,
        startCol: 0,
        endRow: 3,
        endCol: 4,
      );
      // offset 2 hides rows 0,1; row 2 is the first visible (viewRow 0).
      expect(
        AnchorGeometry.gutterRowFor(multi, viewportOffset: 2, viewportRows: 24),
        0,
      );
    });

    test('returns null when fully off-screen', () {
      expect(
        AnchorGeometry.gutterRowFor(range, viewportOffset: 10, viewportRows: 24),
        isNull,
      );
    });
  });
}
