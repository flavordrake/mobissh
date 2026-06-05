// #726 — Ghostty URL smart-select Slice 1: PURE matcher + cell-range mapping.
//
// The view reads the VISIBLE viewport text via flterm's
// `controller.createFormatter(format: plain, unwrap: false).format()` (the
// per-row, viewport-only buffer read) and splits it on `\n` into rows; this
// matcher then finds http/https/www URLs over each logical line (soft-wrapped
// rows re-joined by the cols-width heuristic) and maps each to a 0-based
// viewport cell range. flterm can't render headless (native .so), so the buffer
// READ is owner-validated on device; the detection + mapping math is gated here.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_url_detector.dart';

void main() {
  group('detectGhosttyUrls — single-line detection (#726)', () {
    test('a line with one URL → correct range', () {
      // "see https://example.com now" — URL starts at col 4, ends before col 23.
      const row = 'see https://example.com now';
      final matches = detectGhosttyUrls([row], cols: 80);
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.url, 'https://example.com');
      expect(m.startRow, 0);
      expect(m.endRow, 0);
      expect(m.startCol, 4);
      expect(m.endCol, 4 + 'https://example.com'.length);
    });

    test('no URL → empty', () {
      final matches = detectGhosttyUrls([
        'just some shell output, nothing here',
        r'$ ls -la /home/user',
      ], cols: 80);
      expect(matches, isEmpty);
    });

    test('multiple URLs on separate rows → one match each', () {
      final matches = detectGhosttyUrls([
        'first http://a.test/path',
        'second https://b.test',
      ], cols: 80);
      expect(matches, hasLength(2));
      expect(matches[0].url, 'http://a.test/path');
      expect(matches[0].startRow, 0);
      expect(matches[1].url, 'https://b.test');
      expect(matches[1].startRow, 1);
    });

    test('bare www. host is normalised to https://', () {
      final matches = detectGhosttyUrls([
        'visit www.example.org today',
      ], cols: 80);
      expect(matches, hasLength(1));
      expect(matches.single.url, 'https://www.example.org');
      // The cell range still maps to the raw "www.example.org" text on screen.
      expect(matches.single.startCol, 'visit '.length);
      expect(matches.single.endCol, 'visit '.length + 'www.example.org'.length);
    });

    test('trailing sentence punctuation is excluded from the URL', () {
      final matches = detectGhosttyUrls([
        '(see https://example.com/path).',
      ], cols: 80);
      expect(matches, hasLength(1));
      expect(matches.single.url, 'https://example.com/path');
      // endCol must stop before the trailing ")." — exclusive end.
      final start = '(see '.length;
      expect(matches.single.startCol, start);
      expect(matches.single.endCol, start + 'https://example.com/path'.length);
    });
  });

  group('detectGhosttyUrls — soft-wrap join (#726, #570 parity, #764)', () {
    test('a URL across a soft-wrap → joined into one multi-row range', () {
      // cols=10: row 0 soft-wraps (authoritative rowWraps[0]=true) and the URL
      // continues on row 1. The matcher joins them and detects the whole URL.
      // row0: "x http://e"  (soft-wrapped)
      // row1: "x.co/p end"  (continues the URL: "x.co/p" then " end")
      const row0 = 'x http://e';
      const row1 = 'x.co/p end';
      final matches = detectGhosttyUrls(
        [row0, row1],
        cols: 10,
        rowWraps: const [true, false],
      );
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.url, 'http://ex.co/p');
      // Starts on row 0 at col 2 ("http://e" begins after "x ").
      expect(m.startRow, 0);
      expect(m.startCol, 2);
      // Ends on row 1: joined offset of URL end = 2 + len("http://ex.co/p") = 16
      // → row 16~/10 = 1, col 16%10 = 6 (exclusive, before " end").
      expect(m.endRow, 1);
      expect(m.endCol, 6);
    });

    test('a full-width row that is NOT wrapped is NOT joined (#764 fix)', () {
      // row0 exactly fills cols=10 BUT libghostty reports rowWrap=false: row1
      // starts a brand-new logical line. The OLD width heuristic wrongly joined
      // them (over-capture); the authoritative flag keeps them separate, so the
      // URL on row1 is detected on row1 with its real column.
      const row0 = '0123456789'; // 10 chars, full but NOT a soft-wrap
      const row1 = 'go https://z.io';
      final matches = detectGhosttyUrls(
        [row0, row1],
        cols: 10,
        rowWraps: const [false, false],
      );
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.url, 'https://z.io');
      // NOT joined → the URL starts on row 1 at its true column (after "go ").
      expect(m.startRow, 1);
      expect(m.startCol, 3);
    });
  });

  group('ghosttyCellInUrl / ghosttyUrlAtCell — hit-test (#726)', () {
    const match = GhosttyUrlMatch(
      url: 'https://example.com',
      startCol: 4,
      startRow: 0,
      endCol: 23,
      endRow: 0,
    );

    test('tap cell INSIDE the range → true', () {
      expect(ghosttyCellInUrl(match, col: 4, row: 0), isTrue); // start
      expect(ghosttyCellInUrl(match, col: 10, row: 0), isTrue); // middle
      expect(ghosttyCellInUrl(match, col: 22, row: 0), isTrue); // last cell
    });

    test('tap cell OUTSIDE the range → false', () {
      expect(ghosttyCellInUrl(match, col: 3, row: 0), isFalse); // before start
      expect(
        ghosttyCellInUrl(match, col: 23, row: 0),
        isFalse,
      ); // exclusive end
      expect(ghosttyCellInUrl(match, col: 10, row: 1), isFalse); // wrong row
    });

    test('multi-row range: tail of start row, interior, head of end row', () {
      const wrapped = GhosttyUrlMatch(
        url: 'http://ex.co/p',
        startCol: 2,
        startRow: 0,
        endCol: 6,
        endRow: 1,
      );
      expect(ghosttyCellInUrl(wrapped, col: 9, row: 0), isTrue); // start tail
      expect(
        ghosttyCellInUrl(wrapped, col: 1, row: 0),
        isFalse,
      ); // before start
      expect(ghosttyCellInUrl(wrapped, col: 5, row: 1), isTrue); // end head
      expect(
        ghosttyCellInUrl(wrapped, col: 6, row: 1),
        isFalse,
      ); // exclusive end
    });

    test('ghosttyUrlAtCell returns the containing match or null', () {
      final matches = detectGhosttyUrls([
        'a https://one.test b https://two.test',
      ], cols: 80);
      expect(matches, hasLength(2));
      final hit = ghosttyUrlAtCell(matches, col: matches[1].startCol, row: 0);
      expect(hit?.url, 'https://two.test');
      final miss = ghosttyUrlAtCell(matches, col: 0, row: 0);
      expect(miss, isNull);
    });
  });

  group('detectGhosttyUrls — degenerate input (#726)', () {
    test('empty rows → empty', () {
      expect(detectGhosttyUrls(const [], cols: 80), isEmpty);
    });

    test('cols <= 0 → empty (no grid to map onto)', () {
      expect(detectGhosttyUrls(['https://x.com'], cols: 0), isEmpty);
    });
  });
}
