// #998 slice A — pattern TIERING: block-tier (command-line) anchors coexist
// with span-tier (url/path/OSC-8) anchors.
//
// Today's suppression rules, kept: the ONLY cross-pattern de-dup is OSC-8-wins
// — a SPAN-tier regex match touching a hyperlinked cell is dropped so a
// hyperlinked URL yields ONE exact anchor. New in this slice: that de-dup is
// SCOPED to the span tier, so a BLOCK-tier match (a command line) may CONTAIN
// an OSC-8 link (or any span match) without being suppressed — the foundation
// for slice B's command detection. `rangeGroup` lets a block pattern anchor
// only its capture group's span (the prompt stays un-anchored ink).
//
// No pattern registration changes anywhere: every existing pattern defaults to
// the span tier and behaves byte-identically.

import 'dart:ui';

import 'package:flterm/src/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pure, headless [CellReader] built from per-row text + soft-wrap flags
/// (same seam as structured_text_test.dart).
class _FakeCellReader implements CellReader {
  _FakeCellReader(
    List<String> rowTexts, {
    required this.cols,
    List<bool>? wraps,
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
  final List<List<String?>>? _hyperlinks;

  @override
  final int cols;

  @override
  final int baseAbsRow = 0;

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

/// Per-cell hyperlink map: cells covering [linkText]'s columns on [row] carry
/// [uri]; everything else is null.
List<List<String?>> _linkAt({
  required int rows,
  required int cols,
  required int row,
  required int startCol,
  required int length,
  required String uri,
}) {
  return [
    for (var r = 0; r < rows; r++)
      List<String?>.generate(
        cols,
        (c) =>
            r == row && c >= startCol && c < startCol + length ? uri : null,
      ),
  ];
}

void main() {
  const scanner = StructuredTextScanner();
  final urlPattern = TextPattern.url(
    style: const HighlightStyle(background: Color(0x335B9BD5)),
  );

  /// A synthetic BLOCK-tier "command line" pattern: a `$ ` prompt followed by
  /// the command. [rangeGroup] 1 anchors only the command (prompt excluded).
  /// This is the shape slice B's TextPattern.command will take — slice A ships
  /// NO real command detection, only the tiering machinery it needs.
  final blockPattern = TextPattern(
    id: 'cmd',
    regex: RegExp(r'^\$ (.+)$'),
    tier: TextTier.block,
    rangeGroup: 1,
  );

  group('TextTier defaults — zero registration changes (#998 A)', () {
    test('every built-in pattern is span-tier with no rangeGroup', () {
      expect(TextPattern.url().tier, TextTier.span);
      expect(TextPattern.url().rangeGroup, isNull);
      expect(TextPattern.path().tier, TextTier.span);
      expect(TextPattern.path().rangeGroup, isNull);
      expect(TextPattern.osc8().tier, TextTier.span);
      expect(TextPattern.osc8().rangeGroup, isNull);
    });

    test('a raw TextPattern defaults to span tier', () {
      final p = TextPattern(id: 'x', regex: RegExp('x'));
      expect(p.tier, TextTier.span);
      expect(p.rangeGroup, isNull);
    });

    test('a StructuredMatch defaults to span tier', () {
      const m = StructuredMatch(
        patternId: 'x',
        ranges: [],
        payload: 'x',
      );
      expect(m.tier, TextTier.span);
    });
  });

  group('cross-tier containment — both anchors exist (#998 A)', () {
    test('a block match CONTAINING a span URL suppresses neither', () {
      final reader = _FakeCellReader(
        [r'$ curl https://example.com/x now'],
        cols: 40,
      );
      final matches = scanner.scan(reader, [urlPattern, blockPattern]);

      expect(matches, hasLength(2));
      final url = matches.singleWhere((m) => m.patternId == 'url');
      final cmd = matches.singleWhere((m) => m.patternId == 'cmd');
      expect(url.tier, TextTier.span);
      expect(url.payload, 'https://example.com/x');
      expect(cmd.tier, TextTier.block);
    });

    test('a block match CONTAINING an OSC-8 link survives the de-dup', () {
      // `$ curl https://e.com/x now` where the URL's visible cells carry an
      // OSC-8 hyperlink. Today's de-dup drops ANY regex match touching a
      // hyperlinked cell — correct for the span-tier url regex (one exact
      // OSC-8 anchor, no partial bubble beside it) but it must NOT kill the
      // containing block match.
      const text = r'$ curl https://e.com/x now';
      const uri = 'https://e.com/x';
      final urlStart = text.indexOf('https');
      final reader = _FakeCellReader(
        [text],
        cols: 40,
        hyperlinks: _linkAt(
          rows: 1,
          cols: 40,
          row: 0,
          startCol: urlStart,
          length: uri.length,
          uri: uri,
        ),
      );
      final matches = scanner.scan(
        reader,
        [TextPattern.osc8(), urlPattern, blockPattern],
      );

      // OSC-8 anchor present; span-tier url regex suppressed (today's rule);
      // block-tier command match present (the #998 A change).
      expect(matches.where((m) => m.patternId == 'osc8'), hasLength(1));
      expect(matches.where((m) => m.patternId == 'url'), isEmpty,
          reason: 'span-tier OSC-8-wins de-dup is unchanged');
      expect(matches.where((m) => m.patternId == 'cmd'), hasLength(1),
          reason: 'a block-tier match may CONTAIN an OSC-8 link');
    });

    test('span-tier OSC-8-wins de-dup still fires without a block pattern',
        () {
      const text = 'see https://e.com/x here';
      const uri = 'https://e.com/x';
      final reader = _FakeCellReader(
        [text],
        cols: 40,
        hyperlinks: _linkAt(
          rows: 1,
          cols: 40,
          row: 0,
          startCol: text.indexOf('https'),
          length: uri.length,
          uri: uri,
        ),
      );
      final matches =
          scanner.scan(reader, [TextPattern.osc8(), urlPattern]);
      expect(matches, hasLength(1));
      expect(matches.single.patternId, 'osc8');
    });
  });

  group('rangeGroup — the prompt stays un-anchored ink (#998 A)', () {
    test('a block anchor with rangeGroup excludes the prompt prefix', () {
      final reader = _FakeCellReader(
        [r'$ echo hi'],
        cols: 20,
      );
      final matches = scanner.scan(reader, [blockPattern]);

      expect(matches, hasLength(1));
      final cmd = matches.single;
      expect(cmd.ranges, hasLength(1));
      final r = cmd.ranges.single;
      // Ranges cover 'echo hi' only — cols 2..9; the `$ ` prompt (cols 0-1)
      // is NOT part of the anchor.
      expect(r.startRow, 0);
      expect(r.startCol, 2);
      expect(r.endCol, 9);
      expect(cmd.contains(0, 0), isFalse,
          reason: 'the prompt cell must not hit-test into the block anchor');
      expect(cmd.contains(0, 2), isTrue);
    });

    test('payload still comes from the FULL raw match via normalize', () {
      // rangeGroup narrows GEOMETRY only; normalize sees the full raw match
      // (slice B's scorer needs the prompt) and produces the payload.
      final stripping = TextPattern(
        id: 'cmd',
        regex: RegExp(r'^\$ (.+)$'),
        tier: TextTier.block,
        rangeGroup: 1,
        normalize: (raw) => raw.substring(2),
      );
      final reader = _FakeCellReader([r'$ echo hi'], cols: 20);
      final matches = scanner.scan(reader, [stripping]);
      expect(matches, hasLength(1));
      expect(matches.single.payload, 'echo hi');
    });

    test('rangeGroup spans wrapped rows, still excluding the prompt', () {
      // 20-col grid; the command soft-wraps (authoritative rowWrap flag).
      // Row 0: '$ curl https://exam' (19 visible chars, wraps)
      // Row 1: 'ple.com/xy now'
      final reader = _FakeCellReader(
        [r'$ curl https://exam', 'ple.com/xy now'],
        cols: 20,
        wraps: [true, false],
      );
      final matches = scanner.scan(reader, [urlPattern, blockPattern]);

      final cmd = matches.singleWhere((m) => m.patternId == 'cmd');
      expect(cmd.ranges, hasLength(2));
      expect(cmd.ranges.first.startRow, 0);
      expect(cmd.ranges.first.startCol, 2, reason: 'prompt excluded');
      expect(cmd.ranges.first.endCol, 19);
      expect(cmd.ranges.last.startRow, 1);
      expect(cmd.ranges.last.startCol, 0);
      expect(cmd.ranges.last.endCol, 'ple.com/xy now'.length);
      // The inner URL anchor coexists across the same wrap.
      final url = matches.singleWhere((m) => m.patternId == 'url');
      expect(url.payload, 'https://example.com/xy');
    });

    test('an empty rangeGroup capture emits no anchor', () {
      final emptyGroup = TextPattern(
        id: 'cmd',
        regex: RegExp(r'^\$ ?(.*)$'),
        tier: TextTier.block,
        rangeGroup: 1,
      );
      final reader = _FakeCellReader([r'$ '], cols: 10);
      final matches = scanner.scan(reader, [emptyGroup]);
      expect(matches, isEmpty,
          reason: 'a block anchor needs a non-empty anchored span');
    });
  });
}
