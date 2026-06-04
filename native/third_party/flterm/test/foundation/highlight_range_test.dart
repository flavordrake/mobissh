import 'dart:ui';

import 'package:flterm/src/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HighlightRange', () {
    group('contains (single-row)', () {
      const range = HighlightRange(
        startRow: 4,
        startCol: 6,
        endRow: 4,
        endCol: 12,
      );

      test('a cell inside the range is contained', () {
        expect(range.contains(4, 6), isTrue);
        expect(range.contains(4, 11), isTrue);
      });

      test('endCol is exclusive', () {
        expect(range.contains(4, 12), isFalse);
      });

      test('startCol is inclusive', () {
        expect(range.contains(4, 5), isFalse);
      });

      test('a cell on a different row is not contained', () {
        expect(range.contains(3, 8), isFalse);
        expect(range.contains(5, 8), isFalse);
      });
    });

    group('contains (multi-row)', () {
      const range = HighlightRange(
        startRow: 2,
        startCol: 10,
        endRow: 4,
        endCol: 3,
      );

      test('top row is covered from topCol to end of line', () {
        expect(range.contains(2, 10), isTrue);
        expect(range.contains(2, 9), isFalse);
        expect(range.contains(2, 999), isTrue);
      });

      test('middle rows are fully covered', () {
        expect(range.contains(3, 0), isTrue);
        expect(range.contains(3, 500), isTrue);
      });

      test('bottom row is covered up to bottomCol (exclusive)', () {
        expect(range.contains(4, 0), isTrue);
        expect(range.contains(4, 2), isTrue);
        expect(range.contains(4, 3), isFalse);
      });

      test('rows outside the band are not covered', () {
        expect(range.contains(1, 10), isFalse);
        expect(range.contains(5, 0), isFalse);
      });
    });

    test('normalized accessors order rows/cols', () {
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
      // Containment is direction-independent.
      expect(range.contains(2, 10), isTrue);
      expect(range.contains(4, 2), isTrue);
    });

    test('scroll shifts both rows and preserves payload/colors', () {
      const range = HighlightRange(
        startRow: 2,
        startCol: 1,
        endRow: 2,
        endCol: 5,
        background: Color(0xFF112233),
        underline: Color(0xFF445566),
        payload: 'https://example.com',
      );
      final scrolled = range.scroll(3);
      expect(scrolled.startRow, 5);
      expect(scrolled.endRow, 5);
      expect(scrolled.startCol, 1);
      expect(scrolled.endCol, 5);
      expect(scrolled.background, const Color(0xFF112233));
      expect(scrolled.underline, const Color(0xFF445566));
      expect(scrolled.payload, 'https://example.com');
      expect(identical(range.scroll(0), range), isTrue);
    });

    test('carries an opaque payload', () {
      final url = Uri.parse('https://example.com/a');
      final range = HighlightRange(
        startRow: 0,
        startCol: 0,
        endRow: 0,
        endCol: 4,
        payload: url,
      );
      expect(range.payload, same(url));
    });

    test('equality compares geometry and colors', () {
      const a = HighlightRange(startRow: 1, startCol: 2, endRow: 1, endCol: 6);
      const b = HighlightRange(startRow: 1, startCol: 2, endRow: 1, endCol: 6);
      const c = HighlightRange(startRow: 1, startCol: 2, endRow: 1, endCol: 7);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('HighlightTheme exposes a default translucent background', () {
      expect(HighlightTheme.defaultBackground.a, lessThan(1.0));
    });
  });
}
