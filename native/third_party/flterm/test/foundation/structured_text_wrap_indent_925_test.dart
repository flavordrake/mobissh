// Regression guard for #925 (device-confirmed, v0.1.10+66):
// A long URL EMITTED as terminal output inside the Claude TUI soft-wraps across
// several INDENTED rows. Tap-copy returned only the FIRST visual row (~48 chars)
// because the wrap-join (a) rejected the join when the indented continuation
// row's col 0 was blank, and (b) injected the continuation row's leading indent
// as spaces between the URL halves, breaking the `[^\s]+` URL regex.
//
// The fix makes the wrap-join INDENT-AWARE: it infers the logical block's left
// margin, joins a continuation row whose first non-blank glyph AT/AFTER that
// margin is a bare continuation, and SKIPS the leading indent in the joined
// payload while keeping each row's HighlightRange at its true on-screen columns.
import 'dart:ui';

import 'package:flterm/src/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pure, headless [CellReader] built from per-row text + soft-wrap flags.
/// A space cell reads back as blank (empty), matching a real terminal blank.
class _FakeCellReader implements CellReader {
  _FakeCellReader(List<String> rowTexts, {required this.cols, List<bool>? wraps})
    : _rows = [
        for (final t in rowTexts)
          List<String>.generate(cols, (c) => c < t.length ? t[c] : ' '),
      ],
      _wraps = wraps ?? List<bool>.filled(rowTexts.length, false);

  final List<List<String>> _rows;
  final List<bool> _wraps;

  @override
  final int cols;

  @override
  int get baseAbsRow => 0;

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
  String? hyperlinkAt(int row, int col) => null;
}

void main() {
  const scanner = StructuredTextScanner();
  final patterns = [
    TextPattern.url(style: const HighlightStyle(background: Color(0x335B9BD5))),
  ];

  group('StructuredTextScanner — indented emitted URL wrap (#925)', () {
    test(
      'an INDENTED URL wrapping across 3 rows (NO rowWrap flag) is ONE match '
      'whose payload is the FULL url',
      () {
        // cols=50, 2-col left indent (the Claude-TUI emitted-output case).
        // The URL fills each row to the terminal width (col 50) and the
        // continuation rows carry the SAME 2-col indent. rowWrap is FALSE for
        // ALL rows (the emitted/no-flag case from the device telemetry).
        const cols = 50;
        // Row 0: '  ' + 48 url chars = 50 cols (full width).
        //   '  https://github.com/flavordrake/mobissh/actions/r'
        // Row 1: '  ' + 48 url chars = 50 cols.
        //   '  uns/123456789/job/987654321/step/aaaaaaaaaaaaaaaa'
        // Row 2: '  ' + tail.
        //   '  bbbbbbbbbb'
        const r0 = '  https://github.com/flavordrake/mobissh/actions/r';
        const r1 = '  uns/123456789/job/987654321/step/aaaaaaaaaaaaaaa';
        const r2 = '  bbbbbbbbbb';
        final reader = _FakeCellReader(
          [r0, r1, r2],
          cols: cols,
          wraps: [false, false, false],
        );

        const expected =
            'https://github.com/flavordrake/mobissh/actions/'
            'runs/123456789/job/987654321/step/aaaaaaaaaaaaaaa'
            'bbbbbbbbbb';

        final matches = scanner.scan(reader, patterns);
        final urls = matches.where((m) => m.patternId == 'url').toList();
        expect(urls, hasLength(1), reason: 'one wrapped URL across 3 rows');
        expect(
          urls.single.payload,
          expected,
          reason: 'payload must be the FULL url, not just the first row',
        );
        // The match must span all three rows (one range per row).
        expect(
          urls.single.ranges.length,
          3,
          reason: 'one HighlightRange per wrapped row',
        );
      },
    );

    test(
      'the per-row ranges keep their TRUE on-screen columns (indent NOT shifted)',
      () {
        const cols = 50;
        const r0 = '  https://github.com/flavordrake/mobissh/actions/r';
        const r1 = '  uns/123456789/job/987654321/step/aaaaaaaaaaaaaaa';
        const r2 = '  bbbbbbbbbb';
        final reader = _FakeCellReader(
          [r0, r1, r2],
          cols: cols,
          wraps: [false, false, false],
        );
        final m = scanner
            .scan(reader, patterns)
            .firstWhere((m) => m.patternId == 'url');
        final ranges = m.ranges..sort((a, b) => a.startRow.compareTo(b.startRow));
        // Each row's content starts at the 2-col indent — the range must begin
        // at the actual on-screen column (2), NOT at 0 (the joined-text offset).
        expect(ranges[0].startRow, 0);
        expect(ranges[0].startCol, 2, reason: 'row 0 content starts at indent 2');
        expect(ranges[1].startRow, 1);
        expect(ranges[1].startCol, 2, reason: 'row 1 content starts at indent 2');
        expect(ranges[2].startRow, 2);
        expect(ranges[2].startCol, 2, reason: 'row 2 content starts at indent 2');
        // Row 2 ends at the tail end (2 + 'bbbbbbbbbb'.length = 12).
        expect(ranges[2].endCol, 12);
      },
    );

    test(
      'the AUTHORITATIVE rowWrap=true fast path still yields ONE full match for '
      'an indented URL',
      () {
        const cols = 50;
        const r0 = '  https://github.com/flavordrake/mobissh/actions/r';
        const r1 = '  uns/123456789/job/987654321/step/aaaaaaaaaaaaaaa';
        const r2 = '  bbbbbbbbbb';
        final reader = _FakeCellReader(
          [r0, r1, r2],
          cols: cols,
          wraps: [true, true, false],
        );
        const expected =
            'https://github.com/flavordrake/mobissh/actions/'
            'runs/123456789/job/987654321/step/aaaaaaaaaaaaaaa'
            'bbbbbbbbbb';
        final urls = scanner
            .scan(reader, patterns)
            .where((m) => m.patternId == 'url')
            .toList();
        expect(urls, hasLength(1));
        expect(urls.single.payload, expected);
      },
    );

    test(
      'an INDENTED first row that SOFT-wraps (rowWrap=true) to a COL-0 '
      'continuation keeps the continuation content (indent-skip must not drop it)',
      () {
        // The terminal soft-wrap resumes at COL 0, shallower than the indented
        // first row. The indent-skip must NOT chop the first `indent` cells off
        // the col-0 continuation — that would corrupt the payload. Row 0 is
        // indented (2) and fills the width; row 1 continues at col 0.
        const cols = 50;
        const r0 = '  https://github.com/flavordrake/mobissh/actions/r';
        const r1 = 'uns/123456789/job/987654321'; // col-0 soft-wrap continuation
        final reader = _FakeCellReader(
          [r0, r1],
          cols: cols,
          wraps: [true, false],
        );
        const expected =
            'https://github.com/flavordrake/mobissh/actions/'
            'runs/123456789/job/987654321';
        final urls = scanner
            .scan(reader, patterns)
            .where((m) => m.patternId == 'url')
            .toList();
        expect(urls, hasLength(1), reason: 'one soft-wrapped URL');
        expect(
          urls.single.payload,
          expected,
          reason: 'the col-0 continuation must keep ALL its cells (no indent chop)',
        );
      },
    );

    test(
      '#764 guard: an indented FULL-WIDTH url row followed by a DIFFERENTLY '
      'indented new paragraph stays ONE complete match (no swallow)',
      () {
        // Row 0: a url filling the width at indent 2 (a wrap candidate). Row 1: a
        // sentence at a DIFFERENT (deeper) indent — a separate block, not a wrap
        // of row 0. The indent-aware join must require the SAME margin, so the
        // url does NOT swallow the differently-indented line (#925 discriminator
        // that keeps #764 two-block behavior for indented output).
        const cols = 50;
        const r0 = '  https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        const r1 = '      a separately indented paragraph at indent 6';
        final reader = _FakeCellReader(
          [r0, r1],
          cols: cols,
          wraps: [false, false],
        );
        final urls = scanner
            .scan(reader, patterns)
            .where((m) => m.patternId == 'url')
            .toList();
        expect(urls, hasLength(1), reason: 'exactly one url');
        expect(
          urls.single.payload,
          'https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          reason: 'must NOT swallow the differently-indented next line',
        );
        expect(urls.single.ranges, hasLength(1), reason: 'single-row match');
      },
    );

    test(
      '#764 guard: an indented FULL-WIDTH url row followed by an indented BULLET '
      'line does not merge the bullet text',
      () {
        // Row 0: indented url filling the width (a wrap candidate). Row 1: an
        // indented bullet starts a NEW block — _startsNewBlock must reject the
        // join even though the indent matches.
        const cols = 50;
        const r0 = '  https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        const r1 = '  - a fresh bullet item that is not a continuation';
        final reader = _FakeCellReader(
          [r0, r1],
          cols: cols,
          wraps: [false, false],
        );
        final urls = scanner
            .scan(reader, patterns)
            .where((m) => m.patternId == 'url')
            .toList();
        expect(urls, hasLength(1));
        expect(
          urls.single.payload,
          'https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          reason: 'a bullet line starts a new block — not merged',
        );
      },
    );
  });
}
