// #751 / #764 — wrapped URL must highlight/detect BOTH rows, and ONLY its rows.
//
// `detectGhosttyUrls` reads per-VISIBLE-ROW strings (flterm's `unwrap:false`
// formatter, one row per `\n`) AND the AUTHORITATIVE per-row soft-wrap flags
// (`controller.viewportRowWraps`, libghostty's `rowGetWrap`). It joins row N
// into N+1 IFF `rowWraps[N]` is true — never guessed from row width. It runs the
// URL regex on the joined logical line, then maps each match back to
// per-(row,startCol,endCol) ranges spanning exactly the wrapped rows — so a URL
// wrapping row N→N+1 yields a match covering BOTH rows, the hit-test resolves a
// tap on EITHER half, and a full-width row that is NOT wrapped is never joined.
//
// #764 is the robust replacement for #751's width heuristic: a row that exactly
// fills `cols` but is NOT a soft-wrap (rowWrap=false) must NOT join the next row
// (the case the old `row.length >= cols` guess got wrong → over-capture).
//
// Pure matcher (no FFI / no flterm widget) → unit-testable headless. The owner
// device-validates the rendered underline; this gates the join + range math.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/ghostty_url_detector.dart';

void main() {
  group('detectGhosttyUrls — wrapped URL spans BOTH rows (#751/#764)', () {
    test('single-row URL is unchanged (no spurious wrap)', () {
      const row = 'open https://example.com/path here';
      final matches = detectGhosttyUrls(
        [row],
        cols: 80,
        rowWraps: const [false],
      );
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.url, 'https://example.com/path');
      expect(m.startRow, 0);
      expect(m.endRow, 0);
      expect(m.startCol, 'open '.length);
      expect(m.endCol, 'open '.length + 'https://example.com/path'.length);
    });

    test('URL wrapping row N→N+1 (rowWraps[N]=true) covers BOTH rows', () {
      // cols=20. Row 0 soft-wraps (authoritative flag) and the URL continues on
      // row 1. Row 0 is padded to cols=20 when joined.
      //   row0: "go https://example.c" (rowWraps[0]=true → soft-wrapped)
      //   row1: "om/p done"
      const row0 = 'go https://example.c'; // 20 chars
      const row1 = 'om/p done';
      expect(row0.length, 20);
      final matches = detectGhosttyUrls(
        [row0, row1],
        cols: 20,
        rowWraps: const [true, false],
      );
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
      const row0 = 'go https://example.c'; // 20 chars
      const row1 = 'om/p done';
      final matches = detectGhosttyUrls(
        [row0, row1],
        cols: 20,
        rowWraps: const [true, false],
      );
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

    test(
      'URL on a row that does NOT wrap (rowWraps[N]=false) is single-row',
      () {
        // Row 0's authoritative wrap flag is false → it ended naturally, so the
        // URL must NOT be joined with row 1 (don't over-join).
        //   row0: "see https://a.io " (rowWraps[0]=false)
        //   row1: "next line text"
        const row0 = 'see https://a.io ';
        const row1 = 'next line text';
        final matches = detectGhosttyUrls(
          [row0, row1],
          cols: 80,
          rowWraps: const [false, false],
        );
        expect(matches, hasLength(1));
        final m = matches.single;
        expect(m.url, 'https://a.io');
        expect(m.startRow, 0);
        expect(m.endRow, 0); // single row — NOT joined onto row 1
        expect(m.startCol, 'see '.length);
        expect(m.endCol, 'see '.length + 'https://a.io'.length);
      },
    );

    test('a full-width row that is NOT wrapped is NOT joined (#764)', () {
      // The #764 case the old width heuristic got WRONG: row 0 exactly fills
      // `cols` (a line break padded to width) but libghostty reports rowWrap =
      // FALSE. The authoritative flag must win → row 1 is a separate line.
      const cols = 16;
      const row0 = 'go https://a.io '; // EXACTLY 16 chars, fills the grid
      expect(row0.length, cols);
      final matches = detectGhosttyUrls(
        [row0, 'X next'],
        cols: cols,
        rowWraps: const [false, false], // authoritative: row 0 did NOT wrap
      );
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.url, 'https://a.io');
      expect(m.startRow, 0);
      expect(m.endRow, 0); // NOT joined — rowWrap=false despite full width
    });

    test('a full-width row that IS wrapped joins (the inverse #764 case)', () {
      // Same full-width row, but now libghostty reports rowWrap = TRUE: the URL
      // really does continue onto row 1. Width alone could not tell these apart;
      // the flag does.
      const cols = 16;
      const row0 = 'go https://ab.io'; // 16 chars, fills the grid, wraps
      expect(row0.length, cols);
      const row1 = '/p rest';
      final matches = detectGhosttyUrls(
        [row0, row1],
        cols: cols,
        rowWraps: const [true, false],
      );
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.url, 'https://ab.io/p');
      expect(m.startRow, 0);
      expect(m.endRow, 1);
    });

    test('mixed: a plain single-row URL AND a wrapped URL each detected', () {
      const cols = 20;
      // Row 0: a complete single-row URL (does NOT wrap).
      const row0 = 'a http://one.test x';
      // Row 1 soft-wraps into row 2 carrying a second URL.
      const row1 = 'then http://two.test'; // 20 chars, wraps
      const row2 = '/p end';
      expect(row1.length, 20);
      final matches = detectGhosttyUrls(
        [row0, row1, row2],
        cols: cols,
        rowWraps: const [false, true, false],
      );
      expect(matches, hasLength(2));
      // First URL: single row 0.
      expect(matches[0].url, 'http://one.test');
      expect(matches[0].startRow, 0);
      expect(matches[0].endRow, 0);
      // Second URL: wraps row 1 → row 2.
      expect(matches[1].url, 'http://two.test/p');
      expect(matches[1].startRow, 1);
      expect(matches[1].endRow, 2);
    });

    test('the screenshot case: wrapped URL adjacent to shorter URLs (#764)', () {
      // Reproduces the device report: a long .apk URL wraps across two rows,
      // with shorter native.html URLs on the rows below. The OLD width heuristic
      // over-captured — the wrapped URL's range bled into the adjacent URLs. The
      // authoritative flags must give: ONE 2-row range for the long URL, and a
      // SEPARATE single-row range for each shorter URL, no merge.
      const cols = 40;
      // Row 0 (40 chars) soft-wraps onto row 1 — one long URL.
      const row0 = 'get https://mobissh.ts.net/native-2026060'; // 41? trim
      // Keep row0 exactly cols wide:
      const row0fix = 'get https://mobissh.ts.net/native-202606'; // 40 chars
      expect(row0fix.length, cols);
      const row1 = '05T001621.apk done';
      // Row 2 and row 3 each hold a shorter, complete URL (no wrap).
      const row2 = 'a https://mobissh.ts.net/native.html b';
      const row3 = 'c https://mobissh.ts.net/native.html d';
      final matches = detectGhosttyUrls(
        [row0fix, row1, row2, row3],
        cols: cols,
        rowWraps: const [true, false, false, false],
      );
      expect(matches, hasLength(3));

      // The long wrapped URL: spans rows 0→1, terminates at ".apk".
      final wrapped = matches[0];
      expect(wrapped.url, 'https://mobissh.ts.net/native-20260605T001621.apk');
      expect(wrapped.startRow, 0);
      expect(wrapped.endRow, 1);
      // It must NOT bleed into row 2's URL.
      expect(
        ghosttyUrlAtCell(matches, col: 0, row: 2)?.url,
        isNot(wrapped.url),
      );

      // The two shorter URLs: each its OWN single-row range.
      expect(matches[1].url, 'https://mobissh.ts.net/native.html');
      expect(matches[1].startRow, 2);
      expect(matches[1].endRow, 2);
      expect(matches[2].url, 'https://mobissh.ts.net/native.html');
      expect(matches[2].startRow, 3);
      expect(matches[2].endRow, 3);

      // Hit-test: either half of the wrapped URL → the wrapped URL; a cell in
      // the row-2 URL → that URL, not the wrapped one.
      expect(ghosttyUrlAtCell(matches, col: 10, row: 0)?.url, wrapped.url);
      expect(ghosttyUrlAtCell(matches, col: 3, row: 1)?.url, wrapped.url);
      final row2Hit = ghosttyUrlAtCell(matches, col: 5, row: 2);
      expect(row2Hit?.url, 'https://mobissh.ts.net/native.html');
      expect(row2Hit?.startRow, 2);

      expect(row0.isNotEmpty, isTrue); // keep the draft constant referenced
    });

    test('three-row wrap: URL spanning rows N, N+1, N+2', () {
      const cols = 12;
      const row0 = 'x https://ab'; // 12 chars, wraps
      const row1 = 'cdefghijklmn'; // 12 chars, wraps
      const row2 = '.io/p tail';
      expect(row0.length, cols);
      expect(row1.length, cols);
      final matches = detectGhosttyUrls(
        [row0, row1, row2],
        cols: cols,
        rowWraps: const [true, true, false],
      );
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(m.url, 'https://abcdefghijklmn.io/p');
      expect(m.startRow, 0);
      expect(m.endRow, 2);
      // Hit-test the interior (fully-covered) middle row.
      expect(ghosttyUrlAtCell(matches, col: 5, row: 1)?.url, m.url);
    });
  });
}
