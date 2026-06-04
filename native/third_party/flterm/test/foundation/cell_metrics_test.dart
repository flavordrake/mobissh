import 'dart:ui';

import 'package:flterm/src/foundation/cell_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CellMetrics', () {
    group('equality', () {
      test('compares metrics by value', () {
        const a = CellMetrics(cellWidth: 8.0, cellHeight: 16.0, baseline: 13.0);
        const b = CellMetrics(cellWidth: 8.0, cellHeight: 16.0, baseline: 13.0);
        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);

        const diffWidth = CellMetrics(
          cellWidth: 9.0,
          cellHeight: 16.0,
          baseline: 13.0,
        );
        const diffHeight = CellMetrics(
          cellWidth: 8.0,
          cellHeight: 17.0,
          baseline: 13.0,
        );
        const diffBaseline = CellMetrics(
          cellWidth: 8.0,
          cellHeight: 16.0,
          baseline: 14.0,
        );
        expect(a, isNot(equals(diffWidth)));
        expect(a, isNot(equals(diffHeight)));
        expect(a, isNot(equals(diffBaseline)));
      });
    });

    group('cellAt', () {
      const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

      test('floors pixel position to cell coordinates', () {
        expect(metrics.cellAt(Offset.zero), (0, 0));
        expect(metrics.cellAt(const Offset(3, 7)), (0, 0));
        expect(metrics.cellAt(const Offset(8, 16)), (1, 1));
        expect(metrics.cellAt(const Offset(15.9, 31.9)), (1, 1));
        expect(metrics.cellAt(const Offset(16, 32)), (2, 2));
        expect(metrics.cellAt(const Offset(80, 160)), (10, 10));
      });

      test('negative position produces negative indices', () {
        final (row, col) = metrics.cellAt(const Offset(-1, -1));
        expect(row, -1);
        expect(col, -1);
      });

      test('zero-dimension metrics produce (0, 0)', () {
        const zero = CellMetrics(cellWidth: 0, cellHeight: 0, baseline: 0);
        expect(zero.cellAt(const Offset(100, 100)), (0, 0));
      });
    });

    group('gridSize', () {
      const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

      test('floors pixel dimensions to cell counts', () {
        expect(metrics.gridSize(80, 160), (10, 10));
        expect(metrics.gridSize(87, 175), (10, 10));
        expect(metrics.gridSize(7, 15), (0, 0));
      });

      test('zero-dimension metrics produce (0, 0)', () {
        const zero = CellMetrics(cellWidth: 0, cellHeight: 0, baseline: 0);
        expect(zero.gridSize(800, 600), (0, 0));
      });
    });

    group('cellRect', () {
      const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

      test('returns correct rect at origin offset', () {
        final rect = metrics.cellRect(0, 0, Offset.zero);
        expect(rect, const Rect.fromLTWH(0, 0, 8, 16));
      });

      test('applies row and col offsets', () {
        final rect = metrics.cellRect(2, 3, Offset.zero);
        expect(rect, const Rect.fromLTWH(24, 32, 8, 16));
      });

      test('applies pixel offset', () {
        final rect = metrics.cellRect(0, 0, const Offset(10, 20));
        expect(rect, const Rect.fromLTWH(10, 20, 8, 16));
      });
    });

    group('cellRangeRect', () {
      const metrics = CellMetrics(cellWidth: 8, cellHeight: 16, baseline: 12);

      test('returns correct rect for column range', () {
        final rect = metrics.cellRangeRect(0, 2, 5, Offset.zero);
        expect(rect, const Rect.fromLTWH(16, 0, 24, 16));
      });

      test('applies row and pixel offset', () {
        final rect = metrics.cellRangeRect(3, 0, 4, const Offset(5, 10));
        expect(rect, const Rect.fromLTWH(5, 58, 32, 16));
      });

      test('zero-width range produces zero-width rect', () {
        final rect = metrics.cellRangeRect(0, 3, 3, Offset.zero);
        expect(rect.width, 0);
      });
    });
  });
}
