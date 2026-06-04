// #751 — wrapped URL must highlight/detect BOTH rows.
//
// `detectGhosttyUrls` reads per-VISIBLE-ROW strings (flterm's `unwrap:false`
// formatter, one row per `\n`) and must JOIN soft-wrapped rows (a row exactly
// `cols` wide with no soft break continues onto the next), run the URL regex on
// the joined logical line, then map each match back to per-(row,startCol,endCol)
// ranges spanning the wrapped rows — so a URL wrapping row N→N+1 yields a match
// covering BOTH rows, and the hit-test resolves a tap on EITHER half.
//
// Don't OVER-join: a non-full row (or a full row whose trailing cell is a space)
// ended naturally and does NOT continue onto the next row.
//
// Pure matcher (no FFI / no flterm widget) → unit-testable headless. The owner
// device-validates the rendered underline; this gates the join + range math.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_url_detector.dart';

void main() {
  group('detectGhosttyUrls — wrapped URL spans BOTH rows (#751)', () {
    test('single-row URL is unchanged (no spurious wrap)', () {
      const row = 'open https://example.com/path here';
      final matches = detectGhosttyUrls([row], cols: 80);
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.url, 'https://example.com/path');
      expect(m.startRow, 0);
      expect(m.endRow, 0);
      expect(m.startCol, 'open '.length);
      expect(m.endCol, 'open '.length + 'https://example.com/path'.length);
    });

    test('URL wrapping row N→N+1 (full-width row N) covers BOTH rows', () {
      // cols=20. Row 0 is EXACTLY 20 chars (full-width → soft-wrapped); the URL
      // begins on row 0 and continues onto row 1.
      //   row0: "go https://example." (length must be 20 — full)
      //   row1: "com/p done"
      const row0 = 'go https://example.c'; // 20 chars, full → wraps
      const row1 = 'om/p done';
      expect(row0.length, 20);
      final matches = detectGhosttyUrls([row0, row1], cols: 20);
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.url, 'https://example.com/p');
      // Starts row 0 at col 3 ("https" after "go ").
      expect(m.startRow, 0);
      expect(m.startCol, 3);
      // Spans onto row 1.
      expect(m.endRow, 1);
      // Joined end offset = 3 + len("https://example.com/p") = 3 + 21 = 24 →
      // row 24~/20 = 1, col 24%20 = 4 (exclusive, before " done").
      expect(m.endCol, 4);
    });

    test('hit-test resolves a tap on EITHER half of a wrapped URL', () {
      const row0 = 'go https://example.c'; // 20 chars, full → wraps
      const row1 = 'om/p done';
      final matches = detectGhosttyUrls([row0, row1], cols: 20);
      final m = matches.single;
      // A cell in the tail of row 0 (inside the URL) resolves.
      expect(ghosttyUrlAtCell(matches, col: 10, row: 0)?.url, m.url);
      // The last URL cell on row 0 (col 19) resolves.
      expect(ghosttyUrlAtCell(matches, col: 19, row: 0)?.url, m.url);
      // A cell on row 1 inside the URL continuation resolves (the #751 bug:
      // the second row used to produce NO range, so this was null).
      expect(ghosttyUrlAtCell(matches, col: 0, row: 1)?.url, m.url);
      expect(ghosttyUrlAtCell(matches, col: 3, row: 1)?.url, m.url);
      // Just past the URL end on row 1 (col 4 = the space) does NOT resolve.
      expect(ghosttyUrlAtCell(matches, col: 4, row: 1), isNull);
    });

    test('URL at the end of a NON-full row (trailing space) is single-row', () {
      // Row 0 has a trailing space → it ended naturally, NOT a soft-wrap, so the
      // URL must NOT be joined with row 1 (don't over-join).
      //   row0: "see https://a.io " (trailing space; length 17 < cols)
      //   row1: "next line text"
      const row0 = 'see https://a.io ';
      const row1 = 'next line text';
      final matches = detectGhosttyUrls([row0, row1], cols: 80);
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.url, 'https://a.io');
      expect(m.startRow, 0);
      expect(m.endRow, 0); // single row — NOT joined onto row 1
      expect(m.startCol, 'see '.length);
      expect(m.endCol, 'see '.length + 'https://a.io'.length);
    });

    test('a full row whose last cell is a SPACE is NOT a soft-wrap', () {
      // Row 0 is exactly cols wide but its final cell is a blank — a real line
      // break padded to width, NOT a soft-wrap. Must not join onto row 1.
      const cols = 16;
      const row0 = 'see https://a.io '; // 17? trim → 16 content then space
      // Build a row that is exactly cols long but ends in a space.
      const padded = 'go https://a.io '; // 16 chars, last is a space
      expect(padded.length, cols);
      final matches = detectGhosttyUrls([padded, 'X next'], cols: cols);
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.url, 'https://a.io');
      expect(m.endRow, 0); // NOT joined — trailing space ended the row
      // (row0 unused beyond constructing the realistic case)
      expect(row0.isNotEmpty, isTrue);
    });

    test('mixed: a plain single-row URL AND a wrapped URL each detected', () {
      const cols = 20;
      // Row 0: a complete single-row URL (short, NOT full-width).
      const row0 = 'a http://one.test x';
      // Row 1 full-width → wraps into row 2 carrying a second URL.
      const row1 = 'then http://two.tes'; // length 19 < 20? make it 20
      const row1full = 'then http://two.test'; // 20 chars, full → wraps
      const row2 = '/p end';
      expect(row1full.length, 20);
      final matches = detectGhosttyUrls([row0, row1full, row2], cols: cols);
      expect(matches, hasLength(2));
      // First URL: single row 0.
      expect(matches[0].url, 'http://one.test');
      expect(matches[0].startRow, 0);
      expect(matches[0].endRow, 0);
      // Second URL: wraps row 1 → row 2.
      expect(matches[1].url, 'http://two.test/p');
      expect(matches[1].startRow, 1);
      expect(matches[1].endRow, 2);
      // row1 was a deliberately-too-short draft; keep the analyzer quiet.
      expect(row1.isNotEmpty, isTrue);
    });
  });
}
