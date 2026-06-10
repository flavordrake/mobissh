import 'dart:ui';

import 'package:flterm/src/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pure, headless [CellReader] built from per-row text + soft-wrap flags.
///
/// Each row string is padded/truncated to [cols]; a space cell reads back as a
/// blank (empty content), matching how a real terminal blank cell reads. This
/// is the test seam standing in for libghostty's native `GridRef`/`RenderState`
/// (the same role the old `rows`/`rowWraps` lists played for detectGhosttyUrls).
class _FakeCellReader implements CellReader {
  _FakeCellReader(
    List<String> rowTexts, {
    required this.cols,
    List<bool>? wraps,
    this.baseAbsRow = 0,
    List<List<String?>>? hyperlinks,
    // ignore: prefer_initializing_formals
  }) : _hyperlinks = hyperlinks,
       _rows = [
         for (final t in rowTexts)
           List<String>.generate(
             cols,
             (c) => c < t.length ? t[c] : ' ',
           ),
       ],
       _wraps = wraps ?? List<bool>.filled(rowTexts.length, false);

  final List<List<String>> _rows;
  final List<bool> _wraps;

  /// Per-cell OSC-8 hyperlink URIs: `_hyperlinks[row][col]` is the full URI or
  /// null when the cell carries no hyperlink. Null overall → no hyperlinks at
  /// all (the plain-text case), matching a terminal that emitted no OSC-8.
  final List<List<String?>>? _hyperlinks;

  @override
  final int cols;

  @override
  final int baseAbsRow;

  @override
  int get rows => _rows.length;

  @override
  String cellContent(int row, int col) {
    final ch = _rows[row][col];
    return ch == ' ' ? '' : ch;
  }

  @override
  bool rowWrap(int row) => row >= 0 && row < _wraps.length && _wraps[row];

  @override
  String? hyperlinkAt(int row, int col) {
    final links = _hyperlinks;
    if (links == null) return null;
    if (row < 0 || row >= links.length) return null;
    final rowLinks = links[row];
    if (col < 0 || col >= rowLinks.length) return null;
    return rowLinks[col];
  }
}

/// Build a per-cell hyperlink map for [_FakeCellReader] from a list of
/// per-row [uri] strings: every cell on a row whose text is non-blank (and
/// within `uri.length`) carries [rowUris]'s URI; blanks/out-of-range cells are
/// null. A `null` row URI means the row carries no hyperlink at all.
///
/// This mirrors how libghostty attaches the SAME OSC-8 URI to EVERY visible
/// cell of the link — including wrapped continuation rows — so a maximal
/// same-URI run spans the wrap by construction.
List<List<String?>> _hyperlinkMap(
  List<String> rowTexts,
  List<String?> rowUris, {
  required int cols,
}) {
  return [
    for (var r = 0; r < rowTexts.length; r++)
      List<String?>.generate(cols, (c) {
        final uri = r < rowUris.length ? rowUris[r] : null;
        if (uri == null) return null;
        final t = rowTexts[r];
        // A cell carries the URI iff it holds a visible glyph of the link.
        if (c >= t.length) return null;
        return t[c] == ' ' ? null : uri;
      }),
  ];
}

void main() {
  const scanner = StructuredTextScanner();
  final urlPattern = TextPattern.url(
    style: const HighlightStyle(background: Color(0x335B9BD5)),
  );

  group('StructuredTextScanner — single-row URLs', () {
    test('detects a plain http URL with correct absolute cell range', () {
      final reader = _FakeCellReader(
        ['see https://example.com here'],
        cols: 40,
      );
      final matches = scanner.scan(reader, [urlPattern]);

      expect(matches, hasLength(1));
      expect(matches.single.payload, 'https://example.com');
      expect(matches.single.ranges, hasLength(1));
      final r = matches.single.ranges.single;
      expect(r.startRow, 0);
      expect(r.endRow, 0);
      expect(r.startCol, 4); // 'see ' == 4 chars
      // 'https://example.com' is 19 chars -> end col exclusive == 4 + 19.
      expect(r.endCol, 4 + 'https://example.com'.length);
    });

    test('trims trailing sentence punctuation, not past the URL', () {
      final reader = _FakeCellReader(
        ['(see https://x.com).'],
        cols: 40,
      );
      final matches = scanner.scan(reader, [urlPattern]);
      expect(matches, hasLength(1));
      expect(matches.single.payload, 'https://x.com');
      final r = matches.single.ranges.single;
      expect(r.startCol, 5); // '(see ' == 5
      expect(r.endCol, 5 + 'https://x.com'.length);
    });

    test('normalises a bare www. host to https://', () {
      final reader = _FakeCellReader(['go www.foo.org now'], cols: 30);
      final matches = scanner.scan(reader, [urlPattern]);
      expect(matches, hasLength(1));
      expect(matches.single.payload, 'https://www.foo.org');
    });
  });

  group('StructuredTextScanner — wrapped URLs (#751/#764)', () {
    test(
      'a wrapped URL terminates at its REAL last char on the continuation '
      'row — NOT extended to the row width (#751 over-capture)',
      () {
        // cols=15. Row 0 'aaa https://exa' is FULL (15 chars) and soft-wraps;
        // the continuation 'mple.io and on' holds the URL tail 'mple.io' then a
        // space + trailing text. The old viewport-text approach right-PADDED
        // the wrapped row, so a URL could over-capture to the row's width. Here
        // the end range must stop at 'mple.io' (col 7 exclusive), not col 14.
        final reader = _FakeCellReader(
          [
            'aaa https://exa', // 15 chars FULL — soft-wraps into row 1
            'mple.io and on', // 'mple.io' then ' and on' (real content)
          ],
          cols: 15,
          wraps: [true, false],
        );
        final matches = scanner.scan(reader, [urlPattern]);
        expect(matches, hasLength(1), reason: 'one wrapped URL');
        final m = matches.single;
        expect(m.payload, 'https://example.io');
        expect(m.ranges, hasLength(2));
        // Row 0: URL head from col 4 ('aaa ' == 4) to the row end (col 15).
        expect(m.ranges[0].startRow, 0);
        expect(m.ranges[0].startCol, 4);
        expect(m.ranges[0].endCol, 15);
        // Row 1: tail 'mple.io' — cols 0..7, NOT extended to the row width.
        expect(m.ranges[1].startRow, 1);
        expect(m.ranges[1].startCol, 0);
        expect(m.ranges[1].endCol, 7);
      },
    );

    test(
      'a URL fully contiguous across a wrap (no pad gap) spans both rows '
      'as TWO per-row ranges of one match',
      () {
        // cols=10. 'https://ab' fills row 0 cols 0-9, 'c.com' continues row 1.
        final reader = _FakeCellReader(
          [
            'https://ab',
            'c.com rest',
          ],
          cols: 10,
          wraps: [true, false],
        );
        final matches = scanner.scan(reader, [urlPattern]);
        expect(matches, hasLength(1));
        final m = matches.single;
        expect(m.payload, 'https://abc.com');
        expect(m.ranges, hasLength(2), reason: 'one range per row');
        // Row 0: cols 0..10 (exclusive) — the whole row.
        expect(m.ranges[0].startRow, 0);
        expect(m.ranges[0].startCol, 0);
        expect(m.ranges[0].endCol, 10);
        // Row 1: cols 0..5 ('c.com').
        expect(m.ranges[1].startRow, 1);
        expect(m.ranges[1].startCol, 0);
        expect(m.ranges[1].endCol, 5);
      },
    );

    test('two short URLs on consecutive NON-wrapped rows → TWO matches', () {
      final reader = _FakeCellReader(
        [
          'https://a.com',
          'https://b.com',
        ],
        cols: 20,
        wraps: [false, false], // NOT wrapped — distinct logical lines
      );
      final matches = scanner.scan(reader, [urlPattern]);
      expect(matches, hasLength(2));
      expect(matches[0].payload, 'https://a.com');
      expect(matches[1].payload, 'https://b.com');
      // Each is a single-row range — no merge across rows.
      expect(matches[0].ranges, hasLength(1));
      expect(matches[1].ranges, hasLength(1));
      expect(matches[0].ranges.single.startRow, 0);
      expect(matches[1].ranges.single.startRow, 1);
    });

    test(
      'a wrapped URL adjacent to other single-row URLs: only the wrapped '
      'one spans rows (#764)',
      () {
        // Row 0: a single-row URL. Rows 1->2: a wrapped URL. Row 3: another
        // single-row URL. Only the wrapped one has 2 ranges. A genuinely
        // soft-wrapped row 1 is FULL WIDTH (15 cols, no trailing blank) — the
        // URL content runs to the last column and continues on row 2.
        final reader = _FakeCellReader(
          [
            'https://one.com', // 15 chars, single-row URL
            'https://wrapped', // 15 chars FULL — soft-wraps into row 2
            'd.example.com', // continuation
            'https://two.com', // 15 chars, single-row URL
          ],
          cols: 15,
          wraps: [false, true, false, false],
        );
        final matches = scanner.scan(reader, [urlPattern]);
        expect(matches, hasLength(3));
        final byPayload = {for (final m in matches) m.payload: m};
        expect(byPayload['https://one.com']!.ranges, hasLength(1));
        expect(byPayload['https://two.com']!.ranges, hasLength(1));
        expect(
          byPayload['https://wrappedd.example.com']!.ranges,
          hasLength(2),
          reason: 'only the wrapped URL spans rows',
        );
      },
    );
  });

  group('hard-wrap (tmux: no soft-wrap flag) (#767)', () {
    test(
      'a plain-text URL APP-wrapped NARROWER than the terminal (trailing pad) '
      'joins across rows (0.1.10+27 device bug: CLI-colored, non-OSC-8 URL)',
      () {
        // cols=20 terminal; the app wraps at col 12 and PADS the rest, so the
        // wrapped row's TERMINAL last cell (col 19) is blank — the old full-width
        // check failed here and only the first row was detected. Sibling long
        // rows ending at 12 make 12 the inferred wrap column. The URL spans 2→3.
        final reader = _FakeCellReader(
          [
            'prose filler', // 12 — wrap-col sample
            'more filler.', // 12 — wrap-col sample
            'aa https://e', // 12 — 'aa ' + URL head, padded to 20 by the fake
            'x.io/p tail', // continuation 'x.io/p' then ' tail'
          ],
          cols: 20,
          wraps: [false, false, false, false], // app wrap — NO soft-wrap flag
        );
        final matches = scanner.scan(reader, [urlPattern]);
        final url =
            matches.where((m) => m.payload == 'https://ex.io/p').toList();
        expect(url, hasLength(1), reason: 'app-padded wrapped URL is ONE match');
        final rows = {for (final r in url.single.ranges) r.startRow};
        expect(rows.length >= 2, isTrue,
            reason: 'spans both rows despite the trailing pad on row 2');
      },
    );

    test('a URL hard-wrapped by tmux (rowWrap NOT set) joins across rows', () {
      // tmux hard-wraps at the pane width and never sets the soft-wrap flag.
      // cols=15. Row 0 fills the width with the URL head; row 1 continues with a
      // BARE (non-scheme, non-formatting) tail. wraps all false.
      final reader = _FakeCellReader(
        [
          'https://ex.io/a', // 15 chars FULL, no rowWrap (tmux)
          'bcdef done', // bare continuation 'bcdef' then ' done'
        ],
        cols: 15,
        wraps: [false, false],
      );
      final matches = scanner.scan(reader, [urlPattern]);
      expect(matches, hasLength(1), reason: 'the wrapped URL joins via width');
      final m = matches.single;
      expect(m.payload, 'https://ex.io/abcdef');
      expect(m.ranges, hasLength(2));
      expect(m.ranges[0].startRow, 0);
      expect(m.ranges[0].endCol, 15);
      expect(m.ranges[1].startRow, 1);
      expect(m.ranges[1].startCol, 0);
      expect(m.ranges[1].endCol, 5); // 'bcdef'
    });

    test(
      'a complete URL exactly filling the width is NOT merged into an adjacent '
      'NEW URL on the next row (#764 over-capture stays fixed without rowWrap)',
      () {
        final reader = _FakeCellReader(
          [
            'https://one.com', // 15 chars FULL, complete URL
            'https://two.com', // next row STARTS WITH A SCHEME -> its own URL
          ],
          cols: 15,
          wraps: [false, false],
        );
        final matches = scanner.scan(reader, [urlPattern]);
        expect(matches, hasLength(2), reason: 'two separate URLs, not merged');
        expect(matches[0].payload, 'https://one.com');
        expect(matches[1].payload, 'https://two.com');
        expect(matches[0].ranges, hasLength(1));
        expect(matches[1].ranges, hasLength(1));
      },
    );

    test('a full-width URL row is NOT joined to a bullet-prefixed next line', () {
      final reader = _FakeCellReader(
        [
          'https://ex.io/aa', // 16 chars FULL
          '- a new bullet line', // bullet marker '- ' -> new block
        ],
        cols: 16,
        wraps: [false, false],
      );
      final matches = scanner.scan(reader, [urlPattern]);
      expect(matches, hasLength(1));
      expect(matches.single.payload, 'https://ex.io/aa');
      expect(matches.single.ranges, hasLength(1), reason: 'single row, no join');
    });

    test('a full-width URL row is NOT joined to a whitespace-indented line', () {
      final reader = _FakeCellReader(
        [
          'https://ex.io/aa', // 16 chars FULL
          '  indented prose', // leading space -> new block
        ],
        cols: 16,
        wraps: [false, false],
      );
      final matches = scanner.scan(reader, [urlPattern]);
      expect(matches, hasLength(1));
      expect(matches.single.payload, 'https://ex.io/aa');
      expect(matches.single.ranges, hasLength(1));
    });
  });

  group('StructuredMatch.contains (hit-test halves) (#767)', () {
    late StructuredMatch wrapped;
    late StructuredMatch other;

    setUp(() {
      // cols=13. Row 0 is a FULL-width soft-wrapped URL head; row 1 continues
      // it then has a gap + tail; row 2 is a different single-row URL.
      final reader = _FakeCellReader(
        [
          'https://abcde', // 13 chars FULL — soft-wraps into row 1
          'c.com xxxxxxx', // continues 'c.com', then a space + tail
          'https://zz.io', // 13 chars — a different single-row URL
        ],
        cols: 13,
        wraps: [true, false, false],
      );
      final matches = scanner.scan(reader, [urlPattern]);
      wrapped = matches.firstWhere((m) => m.payload == 'https://abcdec.com');
      other = matches.firstWhere((m) => m.payload == 'https://zz.io');
    });

    test('matchAt on the FIRST half of the wrapped URL resolves it', () {
      expect(wrapped.contains(0, 3), isTrue); // row 0, inside the head
    });

    test('matchAt on the SECOND half of the wrapped URL resolves it', () {
      expect(wrapped.contains(1, 2), isTrue); // row 1, inside 'c.com'
    });

    test('a cell on a DIFFERENT URL is not in the wrapped match', () {
      expect(wrapped.contains(2, 3), isFalse);
      expect(other.contains(2, 3), isTrue);
    });

    test('a non-URL cell is in no match', () {
      // Row 1 col 10 is in the 'xxxxxxx' tail after the URL — not the URL.
      expect(wrapped.contains(1, 10), isFalse);
      expect(other.contains(1, 10), isFalse);
    });
  });

  group('absolute coordinates + EVICTION (#767)', () {
    test('baseAbsRow offsets emitted ranges into the absolute frame', () {
      final reader = _FakeCellReader(
        ['https://x.io'],
        cols: 20,
        baseAbsRow: 100,
      );
      final matches = scanner.scan(reader, [urlPattern]);
      expect(matches.single.ranges.single.startRow, 100);
      expect(matches.single.ranges.single.endRow, 100);
    });

    test(
      'a fresh re-scan after scrollback eviction emits shifted absolute rows '
      '(eviction-correct by construction)',
      () {
        // First scan: the URL sits at absolute row 50.
        final before = _FakeCellReader(
          ['https://x.io'],
          cols: 20,
          baseAbsRow: 50,
        );
        final first = scanner.scan(before, [urlPattern]);
        expect(first.single.ranges.single.startRow, 50);

        // Scrollback evicts 10 oldest lines: the SAME content's absolute row is
        // now 40. A fresh scan re-reads baseAbsRow and emits the corrected row
        // — no ghost mark left at row 50.
        final after = _FakeCellReader(
          ['https://x.io'],
          cols: 20,
          baseAbsRow: 40,
        );
        final second = scanner.scan(after, [urlPattern]);
        expect(second.single.ranges.single.startRow, 40);
      },
    );

    test('content scrolled entirely off the top is simply absent', () {
      // The URL is no longer in the scanned window at all -> no match, no
      // ghost. (The window only contains other text now.)
      final reader = _FakeCellReader(
        ['plain text no url here'],
        cols: 30,
        baseAbsRow: 0,
      );
      expect(scanner.scan(reader, [urlPattern]), isEmpty);
    });
  });

  group('OSC-8 hyperlink source (#767 Slice B)', () {
    final osc8 = TextPattern.osc8();

    test(
      'a hyperlink run spanning TWO rows → ONE osc8 match, payload = the full '
      'URI, ranges span both rows',
      () {
        // The VISIBLE text wraps ('short visi' / 'ble') but EVERY cell carries
        // the SAME full URI — libghostty attaches it to the wrapped cells too.
        const uri = 'https://example.com/a/very/long/path/that/wraps';
        final rowTexts = ['short visi', 'ble rest'];
        final reader = _FakeCellReader(
          rowTexts,
          cols: 10,
          // The link covers 'short visi' on row 0 and 'ble' on row 1.
          hyperlinks: [
            [for (var c = 0; c < 10; c++) c < 'short visi'.length ? uri : null],
            [for (var c = 0; c < 10; c++) c < 'ble'.length ? uri : null],
          ],
        );
        final matches = scanner.scan(reader, [osc8]);
        expect(matches, hasLength(1), reason: 'one maximal same-URI run');
        final m = matches.single;
        expect(m.patternId, 'osc8');
        expect(m.payload, uri, reason: 'payload is the exact full URI');
        expect(m.ranges, hasLength(2), reason: 'one range per wrapped row');
        expect(m.ranges[0].startRow, 0);
        expect(m.ranges[0].startCol, 0);
        expect(m.ranges[0].endCol, 'short visi'.length);
        expect(m.ranges[1].startRow, 1);
        expect(m.ranges[1].startCol, 0);
        expect(m.ranges[1].endCol, 'ble'.length);
        // The continuation row resolves the FULL URI by hit-test.
        expect(m.contains(1, 1), isTrue);
      },
    );

    test(
      'an OSC-8 link APP-wrapped with trailing PADDING still spans both rows '
      '(the 0.1.10+22..+25 device bug)',
      () {
        // cols=15. Row 0 holds the link in cols 0-9 then PADDING (cols 10-14 have
        // NO hyperlink) — an app (e.g. the Claude TUI) wrapped the link at its own
        // content width, NARROWER than the terminal. Row 1 continues the SAME URI.
        // The trailing-padding gap must NOT split the link: the device bug was the
        // first row bubbled while the padded continuation did not, because the
        // scanner flushed its run on the gap. Grouping by URI fixes it.
        const uri = 'https://mobissh.example/native-20260605T160732+0000.apk';
        final reader = _FakeCellReader(
          ['https://aa', 'bb.apk'],
          cols: 15,
          wraps: [false, false], // app/hard wrap — NO soft-wrap flag
          hyperlinks: [
            [for (var c = 0; c < 15; c++) c < 'https://aa'.length ? uri : null],
            [for (var c = 0; c < 15; c++) c < 'bb.apk'.length ? uri : null],
          ],
        );
        final matches = scanner.scan(reader, [osc8]);
        expect(matches, hasLength(1),
            reason: 'one link, NOT split by the trailing-pad gap');
        final m = matches.single;
        expect(m.payload, uri);
        final spannedRows = {for (final r in m.ranges) r.startRow};
        expect(spannedRows, {0, 1},
            reason: 'the bubble must span BOTH rows despite row-0 trailing pad');
        expect(m.contains(1, 1), isTrue,
            reason: 'hit-test resolves the padded continuation');
      },
    );

    test(
      'two DIFFERENT URIs on adjacent cells → TWO separate osc8 matches',
      () {
        const a = 'https://a.example/one';
        const b = 'https://b.example/two';
        // 'AAABBB': cols 0-2 carry uri a, cols 3-5 carry uri b — adjacent, no gap.
        final reader = _FakeCellReader(
          ['AAABBB'],
          cols: 6,
          hyperlinks: [
            [a, a, a, b, b, b],
          ],
        );
        final matches = scanner.scan(reader, [osc8]);
        expect(matches, hasLength(2), reason: 'a URI change splits the run');
        final byPayload = {for (final m in matches) m.payload: m};
        expect(byPayload.keys, containsAll(<String>[a, b]));
        expect(byPayload[a]!.ranges.single.startCol, 0);
        expect(byPayload[a]!.ranges.single.endCol, 3);
        expect(byPayload[b]!.ranges.single.startCol, 3);
        expect(byPayload[b]!.ranges.single.endCol, 6);
      },
    );

    test(
      'same-URI cells separated by a non-link gap → ONE match (same link), the '
      'gap excluded from the ranges',
      () {
        const uri = 'https://x.example/p';
        // Same URI on cols 0-1 and 3-4, non-link gap at col 2. libghostty puts the
        // SAME URI on every cell of a link, so these ARE one link (an app wrapped
        // or padded it) — grouped into ONE match; the gap col 2 is in NO range.
        final reader = _FakeCellReader(
          ['ab cd'],
          cols: 5,
          hyperlinks: [
            [uri, uri, null, uri, uri],
          ],
        );
        final matches = scanner.scan(reader, [osc8]);
        expect(matches, hasLength(1), reason: 'same URI → one link');
        final m = matches.single;
        expect(m.payload, uri);
        expect(m.ranges, hasLength(2),
            reason: 'the gap splits the RANGES, not the match');
        expect(m.ranges[0].startCol, 0);
        expect(m.ranges[0].endCol, 2);
        expect(m.ranges[1].startCol, 3);
        expect(m.ranges[1].endCol, 5);
      },
    );

    test('no hyperlinks at all → no osc8 matches', () {
      final reader = _FakeCellReader(['plain text'], cols: 20);
      expect(scanner.scan(reader, [osc8]), isEmpty);
    });

    test(
      'an EMPTY-string OSC-8 URI → NO match (the #810 "copied but empty" bug)',
      () {
        // libghostty can return an EMPTY string (not null) for a cell inside an
        // empty-URI / torn-down OSC-8 link (`ESC]8;;ESC\\` appears in the device
        // trace). An empty URI must NOT create a match: a non-null-but-empty match
        // is a "URL" with no payload → tap fires "Copied URL" but the clipboard is
        // empty. The scanner must treat empty/whitespace URIs the same as null.
        final reader = _FakeCellReader(
          ['abcde'],
          cols: 5,
          hyperlinks: [
            ['', '', '', '', ''],
          ],
        );
        expect(
          scanner.scan(reader, [osc8]),
          isEmpty,
          reason: 'an empty-string hyperlink URI must not anchor an empty match',
        );
      },
    );

    test(
      'a whitespace-only OSC-8 URI → NO match (no empty-payload anchor)',
      () {
        final reader = _FakeCellReader(
          ['abc'],
          cols: 3,
          hyperlinks: [
            ['   ', '   ', '   '],
          ],
        );
        expect(scanner.scan(reader, [osc8]), isEmpty);
      },
    );

    test(
      'an empty-URI run NEXT TO a real link → only the real link matches',
      () {
        const real = 'https://real.example/p';
        // cols 0-1 carry an empty URI (must be dropped), cols 2-4 carry a real one.
        final reader = _FakeCellReader(
          ['ABcde'],
          cols: 5,
          hyperlinks: [
            ['', '', real, real, real],
          ],
        );
        final matches = scanner.scan(reader, [osc8]);
        expect(matches, hasLength(1),
            reason: 'the empty-URI run is dropped; only the real link remains');
        expect(matches.single.payload, real);
        expect(matches.single.ranges.single.startCol, 2);
      },
    );
  });

  group('OSC-8 wins over the regex URL pattern (de-dup, #767 Slice B)', () {
    final osc8 = TextPattern.osc8();
    final urlPattern = TextPattern.url();

    test(
      'a hyperlinked URL whose VISIBLE text is ALSO URL-shaped → only the osc8 '
      'match (regex suppressed on those cells, no double-cover)',
      () {
        // The visible text is itself a URL the regex would match, but its cells
        // carry a DIFFERENT, fuller OSC-8 URI. OSC-8 must win: ONE osc8 match,
        // the regex match over the same cells is suppressed.
        const visible = 'https://ex.io/2026';
        const fullUri = 'https://ex.io/2026-06-05/full/real/target.apk';
        final reader = _FakeCellReader(
          [visible],
          cols: visible.length,
          hyperlinks: [
            [for (var c = 0; c < visible.length; c++) fullUri],
          ],
        );
        // Run BOTH sources together (the controller registers both).
        final matches = scanner.scan(reader, [urlPattern, osc8]);
        expect(
          matches,
          hasLength(1),
          reason: 'osc8 wins; the overlapping regex match is suppressed',
        );
        final m = matches.single;
        expect(m.patternId, 'osc8');
        expect(m.payload, fullUri, reason: 'the exact full OSC-8 URI');
      },
    );

    test(
      'a hyperlinked URL spanning a wrap suppresses the PARTIAL first-row regex '
      'match → ONE anchor spanning both rows, not a partial bubble beside it',
      () {
        // Row 0 holds a URL-shaped head the regex would match on its own; the
        // full link wraps to row 1. Every cell carries the full URI.
        const fullUri = 'https://mobissh.example/mobissh-native-20260605.apk';
        final rowTexts = ['https://mobis', 'sh.example/x'];
        final reader = _FakeCellReader(
          rowTexts,
          cols: 13,
          wraps: [true, false],
          hyperlinks: _hyperlinkMap(
            rowTexts,
            [fullUri, fullUri],
            cols: 13,
          ),
        );
        final matches = scanner.scan(reader, [urlPattern, osc8]);
        expect(
          matches,
          hasLength(1),
          reason: 'one osc8 anchor; the partial regex head is suppressed',
        );
        final m = matches.single;
        expect(m.patternId, 'osc8');
        expect(m.payload, fullUri);
        expect(m.ranges, hasLength(2), reason: 'spans both wrapped rows');
      },
    );

    test(
      'a PLAIN-TEXT URL with NO OSC-8 still detected by the regex (de-dup does '
      'not break plain-text-only detection)',
      () {
        // No hyperlink map at all → the regex behaves exactly as today.
        final reader = _FakeCellReader(
          ['see https://plain.example here'],
          cols: 40,
        );
        final matches = scanner.scan(reader, [urlPattern, osc8]);
        expect(matches, hasLength(1));
        expect(matches.single.patternId, 'url');
        expect(matches.single.payload, 'https://plain.example');
      },
    );

    test(
      'a plain-text URL on ONE row and a hyperlinked URL on ANOTHER → both '
      'detected (regex for the plain one, osc8 for the linked one)',
      () {
        const fullUri = 'https://linked.example/full/path';
        final reader = _FakeCellReader(
          [
            'plain https://plain.example x',
            'https://visible.example',
          ],
          cols: 30,
          hyperlinks: [
            // Row 0: no hyperlink (plain text).
            List<String?>.filled(30, null),
            // Row 1: the whole visible URL is hyperlinked to a fuller URI.
            [
              for (var c = 0; c < 30; c++)
                c < 'https://visible.example'.length ? fullUri : null,
            ],
          ],
        );
        final matches = scanner.scan(reader, [urlPattern, osc8]);
        final byId = <String, List<StructuredMatch>>{};
        for (final m in matches) {
          byId.putIfAbsent(m.patternId, () => []).add(m);
        }
        expect(byId['url'], hasLength(1), reason: 'the plain URL via regex');
        expect(byId['url']!.single.payload, 'https://plain.example');
        expect(byId['osc8'], hasLength(1), reason: 'the linked URL via osc8');
        expect(byId['osc8']!.single.payload, fullUri);
      },
    );
  });

  group('edge cases', () {
    test('empty pattern list → no matches', () {
      final reader = _FakeCellReader(['https://x.io'], cols: 20);
      expect(scanner.scan(reader, const []), isEmpty);
    });

    test('zero-size grid → no matches', () {
      final reader = _FakeCellReader([], cols: 0);
      expect(scanner.scan(reader, [urlPattern]), isEmpty);
    });

    test('range payload matches the normalized URL', () {
      final reader = _FakeCellReader(['www.foo.com'], cols: 20);
      final m = scanner.scan(reader, [urlPattern]).single;
      expect(m.ranges.single.payload, 'https://www.foo.com');
    });

    test('style background propagates onto emitted ranges', () {
      final pattern = TextPattern.url(
        style: const HighlightStyle(background: Color(0x44FF0000)),
      );
      final reader = _FakeCellReader(['https://x.io'], cols: 20);
      final m = scanner.scan(reader, [pattern]).single;
      expect(m.ranges.single.background, const Color(0x44FF0000));
    });
  });

  // #826: a tappable filesystem path NEVER contains shell metacharacters or
  // globs. On the PRIMARY screen the path detector underlined many SCRIPT tokens
  // that are NOT openable paths — `${UID}`-bearing vars, `*`/`?`/`[N]` globs,
  // `$(...)` command substitutions. The char class `[\w.\-~@+]` already excludes
  // those chars, so the regex matched the TRUNCATED FRAGMENT before the metachar
  // (`/tmp/.ssh_loaded_` out of `/tmp/.ssh_loaded_${UID}_*`); a trailing negative
  // lookahead rejects a match whose very next cell is a metachar/glob char. Clean
  // paths (no adjacent metachar) must STILL match — no over-suppression.
  group('TextPattern.path() — shell metachar / glob rejection (#826)', () {
    final pathPattern = TextPattern.path();

    List<String> pathPayloads(String row, {int? cols}) {
      final reader = _FakeCellReader([row], cols: cols ?? (row.length + 2));
      return scanner
          .scan(reader, [pathPattern])
          .where((m) => m.patternId == 'path')
          .map((m) => '${m.payload}')
          .toList();
    }

    test('shell-var path `/tmp/.ssh_loaded_\${UID}_*` is rejected', () {
      expect(pathPayloads(r'rm -f /tmp/.ssh_loaded_${UID}_*'), isEmpty);
    });

    test(r'`/tmp/.ssh_loaded_${UID}_${boot}` (var, no glob) is rejected', () {
      expect(pathPayloads(r'flag=/tmp/.ssh_loaded_${UID}_${boot}'), isEmpty);
    });

    test('glob path `~/.ssh/*.pub` is rejected', () {
      expect(pathPayloads(r'for pub in ~/.ssh/*.pub'), isEmpty);
    });

    test('glob path `~/.zshrc.bak.*` is rejected', () {
      expect(pathPayloads(r'ls ~/.zshrc.bak.*'), isEmpty);
    });

    test('wildcard mid-path `/var/run/com.apple.launchd.*/Listeners` rejected',
        () {
      expect(pathPayloads(r'/var/run/com.apple.launchd.*/Listeners'), isEmpty);
    });

    test('command-substitution `~/.zshrc.bak.\$(date +%s)` is rejected', () {
      expect(pathPayloads(r'cp ~/.zshrc ~/.zshrc.bak.$(date +%s)'),
          isNot(contains(r'~/.zshrc.bak.')));
    });

    test('bracket glob `~/.ssh/id_[rd]sa` is rejected', () {
      expect(pathPayloads(r'~/.ssh/id_[rd]sa'), isEmpty);
    });

    test('clean absolute `/etc/hosts` STILL detects (no over-suppression)', () {
      expect(pathPayloads('see /etc/hosts here'), contains('/etc/hosts'));
    });

    test('clean home `~/notes.md` STILL detects', () {
      expect(pathPayloads('open ~/notes.md now'), contains('~/notes.md'));
    });

    test('clean explicit-relative `./build.log` STILL detects', () {
      expect(pathPayloads('tail ./build.log'), contains('./build.log'));
    });

    test('clean parent-relative `../src/x.dart` STILL detects', () {
      expect(pathPayloads('edit ../src/x.dart'), contains('../src/x.dart'));
    });

    test('clean long absolute `/etc/ssh/sshd_config` STILL detects', () {
      expect(pathPayloads('cat /etc/ssh/sshd_config'),
          contains('/etc/ssh/sshd_config'));
    });

    test('a path followed by a SPACE then a glob still detects the clean path',
        () {
      // The metachar must be ADJACENT to reject; a space-separated glob token is
      // a different word and must not suppress the clean path before it.
      expect(pathPayloads('cat /etc/hosts *.txt'), contains('/etc/hosts'));
    });

    test('the `://` URL context is still NOT a path (file:// stays a URL)', () {
      expect(pathPayloads('file:///etc/hosts'), isEmpty);
    });
  });

  // #874: the path detector over-matched a whole shell command as ONE file path.
  // A device report (0.1.10+55) showed "the whole line in between blocks is
  // presenting as a file". A path token must TERMINATE at a shell separator /
  // quote (`; | & < > = ' "`) and yield only the clean prefix — so a command
  // line like `/workspace/outl/scripts/top-task 2>&1 > /tmp/tt.md; …` underlines
  // the two REAL paths, not the whole run. Quotes that wrap a path are stripped.
  // The #826 glob/var/command-sub REJECTION must stay intact (a `$`/`*`/`[]`/`()`
  // token is suppressed, NOT trimmed to a clean-looking sub-path).
  group('TextPattern.path() — shell-delimiter termination (#874)', () {
    final pathPattern = TextPattern.path();

    List<String> pathPayloads(String row, {int? cols}) {
      final reader = _FakeCellReader([row], cols: cols ?? (row.length + 2));
      return scanner
          .scan(reader, [pathPattern])
          .where((m) => m.patternId == 'path')
          .map((m) => '${m.payload}')
          .toList();
    }

    test(
      'the offending command line yields the TWO real paths, NOT one giant run',
      () {
        const line = '/workspace/outl/scripts/top-task 2>&1 > /tmp/tt.md; '
            'echo "=== FLAGGED ==="; '
            "sed -n '/^## Flagged/,/^##/{ /^## [F]/q; p }' /tmp/tt.md | "
            'head -15; echo;';
        final got = pathPayloads(line);
        // The two distinct real paths are present...
        expect(got, contains('/workspace/outl/scripts/top-task'));
        expect(got, contains('/tmp/tt.md'));
        // ...and the detected SET is exactly those two (the second /tmp/tt.md
        // occurrence dedups in the set) — never the whole command as one path.
        expect(got.toSet(),
            {'/workspace/outl/scripts/top-task', '/tmp/tt.md'});
        // Specifically: nothing swallowed the trailing shell syntax into a path.
        for (final p in got) {
          expect(p, isNot(contains(' ')));
          expect(p, isNot(contains(';')));
          expect(p, isNot(contains('|')));
          expect(p, isNot(contains('>')));
        }
      },
    );

    test('a path followed by `; cmd` yields the path ONLY (semicolon)', () {
      expect(pathPayloads('/tmp/tt.md; echo x'), contains('/tmp/tt.md'));
      expect(pathPayloads('/tmp/tt.md; echo x'), everyElement(isNot(contains(';'))));
    });

    test('a path followed by ` | grep` yields the path ONLY (pipe)', () {
      expect(pathPayloads('/a/b | grep'), contains('/a/b'));
    });

    test('a path adjacent to `|` (no space) terminates at the pipe', () {
      expect(pathPayloads('/a/b|grep'), contains('/a/b'));
      expect(pathPayloads('/a/b|grep'), everyElement(isNot(contains('|'))));
    });

    test('a path adjacent to `;` (no space) terminates at the semicolon', () {
      expect(pathPayloads('/a/b;rm'), contains('/a/b'));
    });

    test('a redirect tail `> /out` yields the source path then the dest path',
        () {
      final got = pathPayloads('cat /etc/hosts > /tmp/out');
      expect(got, contains('/etc/hosts'));
      expect(got, contains('/tmp/out'));
    });

    test('a double-quoted path `"/a/b"` is detected, quote-stripped', () {
      expect(pathPayloads('"/a/b"'), contains('/a/b'));
      expect(pathPayloads('"/a/b"'), everyElement(isNot(contains('"'))));
    });

    test('a single-quoted path `\'/a/b\'` is detected, quote-stripped', () {
      expect(pathPayloads("'/a/b'"), contains('/a/b'));
      expect(pathPayloads("'/a/b'"), everyElement(isNot(contains("'"))));
    });

    test('a quoted absolute path inside a command is detected', () {
      expect(pathPayloads('cat "/etc/ssh/sshd_config"'),
          contains('/etc/ssh/sshd_config'));
    });

    test('`/a/b && /c/d` yields both paths (ampersand terminates)', () {
      final got = pathPayloads('/a/b && /c/d');
      expect(got, contains('/a/b'));
      expect(got, contains('/c/d'));
    });

    // #826 regression guard — glob/var/command-sub tokens MUST still be SUPPRESSED
    // (terminator-trimming must NOT carve a clean-looking sub-path out of them).
    test(r'regression: `${UID}` shell-var path STILL rejected (#826)', () {
      expect(pathPayloads(r'rm -f /tmp/.ssh_loaded_${UID}_*'), isEmpty);
    });

    test('regression: glob `~/.ssh/*.pub` STILL rejected (#826)', () {
      expect(pathPayloads(r'for pub in ~/.ssh/*.pub'), isEmpty);
    });

    test('regression: command-sub `~/.zshrc.bak.\$(date +%s)` STILL rejected',
        () {
      expect(pathPayloads(r'cp ~/.zshrc ~/.zshrc.bak.$(date +%s)'),
          isNot(contains(r'~/.zshrc.bak.')));
    });

    test('regression: bracket glob `~/.ssh/id_[rd]sa` STILL rejected (#826)',
        () {
      expect(pathPayloads(r'~/.ssh/id_[rd]sa'), isEmpty);
    });

    test('regression: a glob TERMINATED by `;` is STILL rejected, not trimmed',
        () {
      // `/a/b*` is a glob; the trailing `;` must NOT rescue a clean `/a/b*`→`/a/b`
      // — the reject-class `*` suppresses the whole candidate.
      expect(pathPayloads('/a/b*; echo'), isEmpty);
    });

    test('regression: clean paths STILL detect (no over-suppression)', () {
      expect(pathPayloads('see /etc/hosts here'), contains('/etc/hosts'));
      expect(pathPayloads('open ~/notes.md now'), contains('~/notes.md'));
      expect(pathPayloads('edit ../src/x.dart'), contains('../src/x.dart'));
    });

    test(
      'a genuinely long path that WRAPS still matches WHOLE (no over-correction)',
      () {
        // cols=15. Row 0 is full and soft-wraps; the long absolute path spans
        // both rows and must join into ONE match — the delimiter-termination fix
        // must not break legitimate wrap-join.
        final reader = _FakeCellReader(
          [
            '/var/lib/postg', // 14 chars, soft-wraps into row 1
            'resql/data/base', // continuation
          ],
          cols: 15,
          wraps: [true, false],
        );
        final got = scanner
            .scan(reader, [pathPattern])
            .where((m) => m.patternId == 'path')
            .map((m) => '${m.payload}')
            .toList();
        expect(got, contains('/var/lib/postgresql/data/base'));
      },
    );
  });
}
