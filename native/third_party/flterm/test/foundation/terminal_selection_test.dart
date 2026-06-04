import 'package:flterm/src/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TerminalSelection', () {
    group('equality', () {
      test('compares selections by value', () {
        const a = TerminalSelection(
          startRow: 1,
          startCol: 2,
          endRow: 3,
          endCol: 4,
        );
        const b = TerminalSelection(
          startRow: 1,
          startCol: 2,
          endRow: 3,
          endCol: 4,
        );
        const c = TerminalSelection(
          startRow: 1,
          startCol: 2,
          endRow: 3,
          endCol: 5,
        );
        const d = TerminalSelection(
          startRow: 1,
          startCol: 2,
          endRow: 3,
          endCol: 4,
          mode: TerminalSelectionMode.block,
        );

        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
        expect(a, isNot(equals(c)));
        expect(a, isNot(equals(d)));
      });
    });

    group('normalized getters', () {
      test('forward selection', () {
        const sel = TerminalSelection(
          startRow: 1,
          startCol: 5,
          endRow: 3,
          endCol: 4,
        );
        expect(sel.topRow, 1);
        expect(sel.bottomRow, 3);
        expect(sel.topCol, 5);
        expect(sel.bottomCol, 4);
      });

      test('reversed rows', () {
        const sel = TerminalSelection(
          startRow: 3,
          startCol: 4,
          endRow: 1,
          endCol: 5,
        );
        expect(sel.topRow, 1);
        expect(sel.bottomRow, 3);
        expect(sel.topCol, 5);
        expect(sel.bottomCol, 4);
      });

      test('same-row reversed columns', () {
        const sel = TerminalSelection(
          startRow: 2,
          startCol: 9,
          endRow: 2,
          endCol: 4,
        );
        expect(sel.topRow, 2);
        expect(sel.bottomRow, 2);
        expect(sel.topCol, 4);
        expect(sel.bottomCol, 9);
      });

      test('block mode always uses min/max columns', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 7,
          endRow: 2,
          endCol: 3,
          mode: TerminalSelectionMode.block,
        );
        expect(sel.topRow, 0);
        expect(sel.bottomRow, 2);
        expect(sel.topCol, 3);
        expect(sel.bottomCol, 7);
      });
    });

    group('contains', () {
      group('normal mode', () {
        test('treats single-row end column as exclusive', () {
          const sel = TerminalSelection(
            startRow: 2,
            startCol: 4,
            endRow: 2,
            endCol: 9,
          );
          expect(sel.contains(2, 3), isFalse);
          expect(sel.contains(2, 4), isTrue);
          expect(sel.contains(2, 8), isTrue);
          expect(sel.contains(2, 9), isFalse);
          expect(sel.contains(1, 5), isFalse);
          expect(sel.contains(3, 5), isFalse);
        });

        test('spans multi-row selections from start to end columns', () {
          const sel = TerminalSelection(
            startRow: 1,
            startCol: 5,
            endRow: 3,
            endCol: 4,
          );
          expect(sel.contains(1, 4), isFalse);
          expect(sel.contains(1, 5), isTrue);
          expect(sel.contains(1, 79), isTrue);
          expect(sel.contains(2, 0), isTrue);
          expect(sel.contains(2, 79), isTrue);
          expect(sel.contains(3, 3), isTrue);
          expect(sel.contains(3, 4), isFalse);
          expect(sel.contains(0, 5), isFalse);
          expect(sel.contains(4, 0), isFalse);
        });

        test('reversed rows normalizes correctly', () {
          const sel = TerminalSelection(
            startRow: 3,
            startCol: 4,
            endRow: 1,
            endCol: 5,
          );
          expect(sel.contains(1, 4), isFalse);
          expect(sel.contains(1, 5), isTrue);
          expect(sel.contains(2, 0), isTrue);
          expect(sel.contains(3, 3), isTrue);
          expect(sel.contains(3, 4), isFalse);
        });

        test('normalizes single-row reversed columns', () {
          const sel = TerminalSelection(
            startRow: 2,
            startCol: 9,
            endRow: 2,
            endCol: 4,
          );
          expect(sel.contains(2, 3), isFalse);
          expect(sel.contains(2, 4), isTrue);
          expect(sel.contains(2, 8), isTrue);
          expect(sel.contains(2, 9), isFalse);
        });
      });

      group('block mode', () {
        test('treats the end column as exclusive', () {
          const sel = TerminalSelection(
            startRow: 1,
            startCol: 3,
            endRow: 3,
            endCol: 7,
            mode: TerminalSelectionMode.block,
          );
          expect(sel.contains(1, 3), isTrue);
          expect(sel.contains(2, 5), isTrue);
          expect(sel.contains(3, 6), isTrue);
          expect(sel.contains(2, 7), isFalse);
          expect(sel.contains(2, 2), isFalse);
          expect(sel.contains(0, 5), isFalse);
          expect(sel.contains(4, 5), isFalse);
        });

        test('fully reversed normalizes correctly', () {
          const sel = TerminalSelection(
            startRow: 3,
            startCol: 7,
            endRow: 1,
            endCol: 3,
            mode: TerminalSelectionMode.block,
          );
          expect(sel.contains(1, 3), isTrue);
          expect(sel.contains(2, 5), isTrue);
          expect(sel.contains(3, 6), isTrue);
          expect(sel.contains(2, 2), isFalse);
          expect(sel.contains(2, 7), isFalse);
        });

        test('normalizes rows forward and columns backward', () {
          const sel = TerminalSelection(
            startRow: 0,
            startCol: 7,
            endRow: 2,
            endCol: 3,
            mode: TerminalSelectionMode.block,
          );
          expect(sel.contains(0, 3), isTrue);
          expect(sel.contains(1, 5), isTrue);
          expect(sel.contains(2, 6), isTrue);
          expect(sel.contains(1, 2), isFalse);
          expect(sel.contains(1, 7), isFalse);
        });
      });
    });

    group('scroll', () {
      test('shifts both rows by delta', () {
        const sel = TerminalSelection(
          startRow: 3,
          startCol: 5,
          endRow: 7,
          endCol: 10,
        );
        final result = sel.scroll(-2);
        expect(result.startRow, 1);
        expect(result.endRow, 5);
        expect(result.startCol, 5);
        expect(result.endCol, 10);
        expect(result.mode, TerminalSelectionMode.normal);
      });

      test('preserves selection when fully off screen', () {
        const sel = TerminalSelection(
          startRow: 1,
          startCol: 0,
          endRow: 2,
          endCol: 5,
        );
        final result = sel.scroll(-3);
        expect(result.startRow, -2);
        expect(result.endRow, -1);
      });

      test('preserves selection when partially off screen', () {
        const sel = TerminalSelection(
          startRow: 1,
          startCol: 0,
          endRow: 5,
          endCol: 10,
        );
        final result = sel.scroll(-3);
        expect(result.startRow, -2);
        expect(result.endRow, 2);
      });

      test('returns same instance for zero delta', () {
        const sel = TerminalSelection(
          startRow: 3,
          startCol: 5,
          endRow: 7,
          endCol: 10,
        );
        expect(identical(sel.scroll(0), sel), isTrue);
      });

      test('positive delta shifts rows down', () {
        const sel = TerminalSelection(
          startRow: 3,
          startCol: 0,
          endRow: 5,
          endCol: 10,
        );
        final result = sel.scroll(2);
        expect(result.startRow, 5);
        expect(result.endRow, 7);
      });

      test('preserves mode', () {
        const sel = TerminalSelection(
          startRow: 3,
          startCol: 0,
          endRow: 5,
          endCol: 10,
          mode: TerminalSelectionMode.block,
        );
        final result = sel.scroll(-1);
        expect(result.mode, TerminalSelectionMode.block);
      });
    });

    group('moveEnd', () {
      const totalCols = 80;
      const totalRows = 24;

      test('right moves end column by one', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: 0,
          endCol: 10,
        );
        final result = sel.moveEnd(
          0,
          1,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, 0);
        expect(result.endCol, 11);
        expect(result.startRow, 0);
        expect(result.startCol, 5);
      });

      test('left moves end column by one', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: 0,
          endCol: 10,
        );
        final result = sel.moveEnd(
          0,
          -1,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, 0);
        expect(result.endCol, 9);
      });

      test('up moves end row by one', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: 2,
          endCol: 10,
        );
        final result = sel.moveEnd(
          -1,
          0,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, 1);
        expect(result.endCol, 10);
      });

      test('down moves end row by one', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: 2,
          endCol: 10,
        );
        final result = sel.moveEnd(
          1,
          0,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, 3);
        expect(result.endCol, 10);
      });

      test('right wraps to next row at end of line', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: 0,
          endCol: totalCols,
        );
        final result = sel.moveEnd(
          0,
          1,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, 1);
        expect(result.endCol, 0);
      });

      test('left wraps to previous row at start of line', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: 1,
          endCol: 0,
        );
        final result = sel.moveEnd(
          0,
          -1,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, 0);
        expect(result.endCol, totalCols);
      });

      test('clamps at top-left', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: 0,
          endCol: 0,
        );
        final result = sel.moveEnd(
          0,
          -1,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, 0);
        expect(result.endCol, 0);
      });

      test('clamps up at row 0', () {
        const sel = TerminalSelection(
          startRow: 1,
          startCol: 5,
          endRow: 0,
          endCol: 3,
        );
        final result = sel.moveEnd(
          -1,
          0,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, 0);
        expect(result.endCol, 3);
      });

      test('clamps down at last row', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: totalRows - 1,
          endCol: 10,
        );
        final result = sel.moveEnd(
          1,
          0,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, totalRows - 1);
        expect(result.endCol, 10);
      });

      test('clamps at bottom-right', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: totalRows - 1,
          endCol: totalCols,
        );
        final result = sel.moveEnd(
          0,
          1,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, totalRows - 1);
        expect(result.endCol, totalCols);
      });

      test('preserves mode', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: 1,
          endCol: 10,
          mode: TerminalSelectionMode.block,
        );
        final result = sel.moveEnd(
          0,
          1,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.mode, TerminalSelectionMode.block);
      });

      test('block mode does not wrap horizontally', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: 1,
          endCol: totalCols,
          mode: TerminalSelectionMode.block,
        );
        final result = sel.moveEnd(
          0,
          1,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, 1);
        expect(result.endCol, totalCols);
      });

      test('block mode clamps column at 0', () {
        const sel = TerminalSelection(
          startRow: 0,
          startCol: 5,
          endRow: 1,
          endCol: 0,
          mode: TerminalSelectionMode.block,
        );
        final result = sel.moveEnd(
          0,
          -1,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(result.endRow, 1);
        expect(result.endCol, 0);
      });

      test('block mode clamps rows at grid boundaries', () {
        const sel = TerminalSelection(
          startRow: 5,
          startCol: 3,
          endRow: 0,
          endCol: 7,
          mode: TerminalSelectionMode.block,
        );
        final up = sel.moveEnd(
          -1,
          0,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(up.endRow, 0);
        expect(up.endCol, 7);

        const selBottom = TerminalSelection(
          startRow: 0,
          startCol: 3,
          endRow: totalRows - 1,
          endCol: 7,
          mode: TerminalSelectionMode.block,
        );
        final down = selBottom.moveEnd(
          1,
          0,
          totalCols: totalCols,
          totalRows: totalRows,
        );
        expect(down.endRow, totalRows - 1);
        expect(down.endCol, 7);
      });
    });
  });
}
