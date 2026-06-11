// Regression guard from a real device report (2026-06-11T00-05-49, on +55):
// Claude Code spinner/status lines — no slash, no URL — were highlighted as
// file paths by the pre-#874 matcher (whole-line dashed underline + folder
// icons). The #874 terminate-at-shell-delimiters overhaul must keep ALL of
// these matching NOTHING.
import 'dart:ui';

import 'package:flterm/src/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

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
    TextPattern.path(style: const HighlightStyle(background: Color(0x335B9BD5))),
  ];

  test('spinner/status lines from the device report match nothing', () {
    final lines = <String>[
      '✻ Razzle-dazzling… (1m 14s · ↓ 4.2k tokens)',
      '· Razzle-dazzling… (1m 30s · ↓ 4.8k tokens)',
      '=== nvvpn container config ===',
      'Image: nvvpn:local',
      'NetworkMode: nvvpn_default',
      '… +73 lines (ctrl+o to expand)',
      'Allowed by PermissionRequest hook',
      'esc to interrupt',
    ];
    for (final l in lines) {
      final reader = _FakeCellReader([l], cols: 60);
      final matches = scanner.scan(reader, patterns);
      expect(
        matches,
        isEmpty,
        reason: 'over-match regression (#874) on: $l → '
            '${matches.map((m) => '[${m.patternId}] ${m.payload}').toList()}',
      );
    }
  });

  test('spinner line wrapped across rows still matches nothing', () {
    // On-device these lines live in a tmux pane and may be soft-wrapped; the
    // wrap-join must not assemble a path candidate out of the joined text.
    final reader = _FakeCellReader(
      ['✻ Razzle-dazzling… (1m 14s', ' · ↓ 4.2k tokens)'],
      cols: 26,
      wraps: [true, false],
    );
    expect(scanner.scan(reader, patterns), isEmpty);
  });
}
