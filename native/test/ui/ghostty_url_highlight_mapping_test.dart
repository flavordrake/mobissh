// #755 Slice 1c — URL highlight is now drawn at the SOURCE by flterm's own
// `HighlightPainter` from `controller.highlights`, NOT by the deleted host
// `GhosttyUrlHighlightPainter` overlay (the #748/#699/#723 underline-drift bug).
//
// `ghosttyUrlMatchesToHighlights` is the pure adapter that maps detected
// `GhosttyUrlMatch`es (0-based VIEWPORT cells) to flterm `HighlightRange`s in
// ABSOLUTE buffer-row space. The critical contract is the viewport->buffer row
// mapping (`absoluteRow = viewportRow + viewportOffset`, the same `.scroll`
// pattern flterm's selection uses), the payload carrying the URL, and an empty
// input clearing the highlights. No FFI / no Flutter binding -> headless.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';
import 'package:mobissh/ui/ghostty_url_detector.dart';

void main() {
  group('ghosttyUrlMatchesToHighlights — viewport->buffer mapping (#755)', () {
    const color = Color(0x335B9BD5);

    test(
      'empty matches -> empty highlights (clears controller.highlights)',
      () {
        expect(
          ghosttyUrlMatchesToHighlights(
            const [],
            viewportOffset: 12,
            color: color,
          ),
          isEmpty,
        );
      },
    );

    test('viewportOffset 0: viewport rows map straight to buffer rows', () {
      const match = GhosttyUrlMatch(
        url: 'https://example.com',
        startCol: 6,
        startRow: 2,
        endCol: 25,
        endRow: 2,
      );
      final ranges = ghosttyUrlMatchesToHighlights(
        const [match],
        viewportOffset: 0,
        color: color,
      );
      expect(ranges, hasLength(1));
      final r = ranges.single;
      expect(r.startRow, 2);
      expect(r.endRow, 2);
      // Columns map straight across, end col stays EXCLUSIVE.
      expect(r.startCol, 6);
      expect(r.endCol, 25);
      // Payload carries the URL for a later highlightAt hit-test (Slice 5).
      expect(r.payload, 'https://example.com');
      // The subtle fill is the supplied theme colour.
      expect(r.background, color);
    });

    test('viewportOffset shifts BOTH rows into absolute buffer space', () {
      const match = GhosttyUrlMatch(
        url: 'https://a.test/path',
        startCol: 0,
        startRow: 1,
        endCol: 10,
        endRow: 1,
      );
      // Scrolled up 40 rows: viewport row 1 is absolute buffer row 41 — the same
      // `viewportRow + scrollbar.offset` mapping flterm's selection + highlight
      // painter use (painter renders absRow at viewport `absRow - offset`).
      final r = ghosttyUrlMatchesToHighlights(
        const [match],
        viewportOffset: 40,
        color: color,
      ).single;
      expect(r.startRow, 41);
      expect(r.endRow, 41);
      // Columns are NOT shifted by the row offset.
      expect(r.startCol, 0);
      expect(r.endCol, 10);
      // And flterm's painter would map it back to viewport row 1 at offset 40.
      expect(r.topRow - 40, 1);
    });

    test('soft-wrapped (multi-row) URL maps each endpoint by the offset', () {
      const match = GhosttyUrlMatch(
        url: 'https://example.com/very/long/wrapped/path',
        startCol: 70,
        startRow: 3,
        endCol: 12,
        endRow: 4,
      );
      final r = ghosttyUrlMatchesToHighlights(
        const [match],
        viewportOffset: 5,
        color: color,
      ).single;
      expect(r.startRow, 8); // 3 + 5
      expect(r.endRow, 9); //  4 + 5
      expect(r.startCol, 70);
      expect(r.endCol, 12);
      expect(r.payload, match.url);
    });

    test('multiple matches preserve order, each with its own payload', () {
      const a = GhosttyUrlMatch(
        url: 'https://one.test',
        startCol: 1,
        startRow: 0,
        endCol: 5,
        endRow: 0,
      );
      const b = GhosttyUrlMatch(
        url: 'https://two.test',
        startCol: 2,
        startRow: 6,
        endCol: 9,
        endRow: 6,
      );
      final ranges = ghosttyUrlMatchesToHighlights(
        const [a, b],
        viewportOffset: 3,
        color: color,
      );
      expect(ranges, hasLength(2));
      expect(ranges[0].payload, 'https://one.test');
      expect(ranges[0].startRow, 3);
      expect(ranges[1].payload, 'https://two.test');
      expect(ranges[1].startRow, 9);
    });

    test('produced ranges hit-test back to the URL via contains', () {
      const match = GhosttyUrlMatch(
        url: 'https://hit.test',
        startCol: 4,
        startRow: 2,
        endCol: 12,
        endRow: 2,
      );
      final r = ghosttyUrlMatchesToHighlights(
        const [match],
        viewportOffset: 10,
        color: color,
      ).single;
      // Absolute row 12 (viewport row 2 + offset 10), within the cols.
      expect(r.contains(12, 4), isTrue);
      expect(r.contains(12, 11), isTrue);
      expect(r.contains(12, 12), isFalse); // exclusive end col
      expect(r.contains(11, 4), isFalse); // wrong row
    });
  });

  group('ghosttySameUrlMatches — change detection (#726/#755)', () {
    const m = GhosttyUrlMatch(
      url: 'https://x.test',
      startCol: 0,
      startRow: 0,
      endCol: 4,
      endRow: 0,
    );

    test('identical lists are equal', () {
      expect(ghosttySameUrlMatches(const [m], const [m]), isTrue);
    });

    test('different length is not equal', () {
      expect(ghosttySameUrlMatches(const [m], const []), isFalse);
    });

    test('different content is not equal', () {
      const other = GhosttyUrlMatch(
        url: 'https://y.test',
        startCol: 0,
        startRow: 0,
        endCol: 4,
        endRow: 0,
      );
      expect(ghosttySameUrlMatches(const [m], const [other]), isFalse);
    });
  });
}
