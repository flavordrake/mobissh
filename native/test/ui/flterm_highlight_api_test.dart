// Slice 1b (#755) — verifies the additive highlight API that flterm now
// exposes for Slice 1c to consume. This pins the PUBLIC surface reachable
// through `package:flterm/flterm.dart`: the `HighlightRange` model, its
// `HighlightTheme` default color, and `CellMetrics` (so 1c can map detected
// viewport cells → highlight ranges using flterm's REAL cell geometry rather
// than the re-derived overlay metrics that drifted in #748/#699/#723).
//
// No FFI: this exercises pure-Dart model + geometry, so it runs on every
// commit in the fast gate (gate 2), not only the ffi-tagged tier.

import 'dart:ui';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('flterm highlight API (exported surface)', () {
    test('HighlightRange is constructible with payload and colors', () {
      const range = HighlightRange(
        startRow: 3,
        startCol: 4,
        endRow: 3,
        endCol: 18,
        background: Color(0x330000FF),
        underline: Color(0xFF0000FF),
        payload: 'https://example.com',
      );
      expect(range.startRow, 3);
      expect(range.endCol, 18);
      expect(range.payload, 'https://example.com');
    });

    test('contains follows the inclusive-start / exclusive-end convention', () {
      const range = HighlightRange(
        startRow: 0,
        startCol: 2,
        endRow: 0,
        endCol: 6,
      );
      expect(range.contains(0, 2), isTrue);
      expect(range.contains(0, 5), isTrue);
      expect(range.contains(0, 6), isFalse);
      expect(range.contains(0, 1), isFalse);
    });

    test('contains covers a multi-row range like flowing text', () {
      // Same shape `controller.highlightAt` hit-tests against (absolute rows).
      const range = HighlightRange(
        startRow: 0,
        startCol: 6,
        endRow: 2,
        endCol: 4,
        payload: 'multi',
      );
      // Top row: from startCol to end of line.
      expect(range.contains(0, 6), isTrue);
      expect(range.contains(0, 5), isFalse);
      // Middle row: fully covered.
      expect(range.contains(1, 0), isTrue);
      // Bottom row: up to bottomCol (exclusive).
      expect(range.contains(2, 3), isTrue);
      expect(range.contains(2, 4), isFalse);
      // Outside the band.
      expect(range.contains(3, 0), isFalse);
    });

    test('normalized accessors are direction-independent', () {
      const range = HighlightRange(
        startRow: 4,
        startCol: 3,
        endRow: 2,
        endCol: 10,
      );
      expect(range.topRow, 2);
      expect(range.bottomRow, 4);
      expect(range.topCol, 10);
      expect(range.bottomCol, 3);
    });

    test('scroll re-anchors rows while preserving payload', () {
      const range = HighlightRange(
        startRow: 1,
        startCol: 0,
        endRow: 1,
        endCol: 5,
        payload: 'p',
      );
      final scrolled = range.scroll(7);
      expect(scrolled.startRow, 8);
      expect(scrolled.endRow, 8);
      expect(scrolled.payload, 'p');
    });

    test('HighlightTheme provides a translucent default fill', () {
      expect(HighlightTheme.defaultBackground.a, lessThan(1.0));
    });

    test(
      'CellMetrics.cellRangeRect maps a cell run to pixels (1c geometry)',
      () {
        const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);
        final rect = metrics.cellRangeRect(2, 1, 4, Offset.zero);
        // viewport row 2, cols 1..3 inclusive (endCol 4 exclusive).
        expect(rect.left, 8);
        expect(rect.top, 32);
        expect(rect.width, 24);
        expect(rect.height, 16);
      },
    );
  });
}
