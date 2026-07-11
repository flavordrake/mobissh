// TextPattern.relativePath() matrix (#1036, MobiSSH issue).
//
// The RELATIVE-path pattern is deliberately BROAD at the shape level: any
// >=2-segment `a/b` token in the path charset matches (`and/or` included) —
// the app-side #990 SFTP-stat verifier is the precision gate (a relpath anchor
// shows NO affordance until its cwd-resolved absolute path verifies, so a
// prose token that never resolves simply never shows). What the shape DOES
// exclude is anything another pattern already owns or that cannot be a
// cwd-relative path: absolute (`/a/b`), home (`~/x`), explicit-relative
// (`./x`, `../x` — TextPattern.path matches those), scheme contexts
// (`https://x/y` must stay one URL), and glob/shell-var contaminated tokens
// (#826 reject class, mirrored from the absolute pattern).

import 'package:flterm/src/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal single/multi-row [CellReader] fake (mirrors structured_text_test).
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
  final relPattern = TextPattern.relativePath();

  List<String> payloadsIn(String row, {int? cols}) {
    final reader = _FakeCellReader([row], cols: cols ?? (row.length + 2));
    return [
      for (final m in scanner.scan(reader, [relPattern])) '${m.payload}',
    ];
  }

  group('TextPattern.relativePath() — matches (#1036)', () {
    test('the owner-report shape: specs/001-sound-foundation/spec.md', () {
      expect(
        payloadsIn('wrote specs/001-sound-foundation/spec.md today'),
        ['specs/001-sound-foundation/spec.md'],
      );
    });

    test('two bare segments with an extension', () {
      expect(payloadsIn('cat a/b.txt'), ['a/b.txt']);
    });

    test('two bare segments without extension (prose-shaped is FINE — the '
        'verifier is the precision gate)', () {
      expect(payloadsIn('use and/or here'), ['and/or']);
    });

    test('dot-leading first segment (.claude/rules)', () {
      expect(payloadsIn('see .claude/rules now'), ['.claude/rules']);
    });

    test('trailing slash on a >=2-segment token is kept', () {
      expect(payloadsIn('ls src/util/'), ['src/util/']);
    });

    test('trailing sentence punctuation is trimmed', () {
      expect(payloadsIn('open a/b.txt.'), ['a/b.txt']);
      expect(payloadsIn('(see specs/x/y.md)'), ['specs/x/y.md']);
    });

    test('quoted relative path matches with quotes stripped', () {
      expect(payloadsIn('cat "a/b.txt"'), ['a/b.txt']);
    });

    test('distinct id relpath, span tier', () {
      final reader = _FakeCellReader(['x a/b y'], cols: 10);
      final matches = scanner.scan(reader, [relPattern]);
      expect(matches, hasLength(1));
      expect(matches.first.patternId, 'relpath');
      expect(matches.first.tier, TextTier.span);
    });
  });

  group('TextPattern.relativePath() — rejections', () {
    test('absolute path never matches (owned by TextPattern.path)', () {
      expect(payloadsIn('see /etc/hosts now'), isEmpty);
    });

    test('home path never matches (~/x owned by TextPattern.path)', () {
      expect(payloadsIn('see ~/notes/todo.md'), isEmpty);
    });

    test('explicit-relative never matches (./x ../x owned by TextPattern.path)',
        () {
      expect(payloadsIn('run ./scripts/gate.sh'), isEmpty);
      expect(payloadsIn('cd ../lib/src'), isEmpty);
    });

    test('~user/rest never matches (another user home, not cwd-relative)', () {
      expect(payloadsIn('see ~bob/notes'), isEmpty);
    });

    test('a scheme URL never yields a relpath fragment', () {
      // `example.com/docs` sits after `https://` — the :// context must not
      // anchor a relative path inside a URL.
      expect(payloadsIn('open https://example.com/docs now'), isEmpty);
      expect(payloadsIn('file://host/tmp/x'), isEmpty);
    });

    test('single segment never matches (no slash)', () {
      expect(payloadsIn('cat notes.txt'), isEmpty);
    });

    test('trailing-slash-only single segment never matches', () {
      expect(payloadsIn('ls src/'), isEmpty);
    });

    test('glob/shell-var contaminated token is suppressed (#826 class)', () {
      expect(payloadsIn(r'rm logs/*.log'), isEmpty);
      expect(payloadsIn(r'echo tmp/${UID}_x'), isEmpty);
    });

    test('shell-delimiter terminates the path (#874 class)', () {
      expect(payloadsIn('cat a/b.txt;echo x'), ['a/b.txt']);
    });

    test('never anchors mid-token after a path char', () {
      // `b/c` inside `a/b/c`… the whole token is one match, not two.
      expect(payloadsIn('x a/b/c y'), ['a/b/c']);
    });
  });

  group('TextPattern.relativePath() — wrap join', () {
    test('a soft-wrapped relative path joins to one match', () {
      final reader = _FakeCellReader(
        ['see specs/001-sound', '-foundation/spec.md'],
        cols: 19,
        wraps: [true, false],
      );
      final matches = scanner.scan(reader, [relPattern]);
      expect(matches, hasLength(1));
      expect('${matches.first.payload}', 'specs/001-sound-foundation/spec.md');
      expect(matches.first.ranges, hasLength(2));
    });
  });
}
