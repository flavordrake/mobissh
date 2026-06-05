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
  }) : _rows = [
         for (final t in rowTexts)
           List<String>.generate(
             cols,
             (c) => c < t.length ? t[c] : ' ',
           ),
       ],
       _wraps = wraps ?? List<bool>.filled(rowTexts.length, false);

  final List<List<String>> _rows;
  final List<bool> _wraps;

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
}
