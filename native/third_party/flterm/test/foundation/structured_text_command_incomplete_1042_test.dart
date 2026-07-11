// #1042 — command anchors at unjoinable wraps: bounded IN-BLOCK continuation
// joins + the `maybeIncomplete` honesty marking.
//
// Owner device report (+134, trace 2026-07-11T02-32-14): a wrapped command
// anchored only its FIRST row and the copy gave a partial command with NO
// indication. Two-part fix, tested here at the scanner level:
//
//   * RECALL (bounded): within an ESTABLISHED command block (STRONG prompt +
//     scored body — the #998 B/#1013 machinery), a head row whose content
//     reaches the wrap boundary (the #1007 corroborated-wrapCol / grid-edge
//     machinery, reused) continues onto the next row even without URL-token
//     evidence — stopping at blank rows, fresh prompt rows, and new-block
//     starts. A word-wrap seam (head ends SHORT of the grid edge — the TUI
//     consumed the breaking space) reinserts ONE space; an exact grid-edge
//     seam is a mid-token hard break and joins spaceless.
//   * HONESTY: when a command anchor's successor row was REJECTED as a
//     continuation while looking like block content (non-blank, not a prompt,
//     not a new block) AND either the anchor's last row reaches the wrap
//     boundary OR the successor sits DEEPER than the block indent (the
//     Claude-TUI continuation band — the owner-trace shape), the match/anchor
//     carries `maybeIncomplete: true`. Precision stance unchanged: the join
//     still demands boundary evidence; the marking is the honesty valve.
//
// Shapes below are REAL corpus text (the owner trace + the 07-02 wrangler
// trace), not synthetic prose. The #1013 controls live in
// structured_text_command_test.dart and must stay green alongside.

import 'package:flterm/src/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure headless [CellReader] from per-row text + soft-wrap flags (same seam
/// as structured_text_command_test.dart).
class _FakeCellReader implements CellReader {
  _FakeCellReader(
    List<String> rowTexts, {
    required this.cols,
    List<bool>? wraps,
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
  String? hyperlinkAt(int row, int col) => null;
}

void main() {
  const scanner = StructuredTextScanner();
  final command = TextPattern.command();
  final url = TextPattern.url();

  List<StructuredMatch> commandsIn(
    List<String> rows, {
    required int cols,
    List<bool>? wraps,
  }) {
    final reader = _FakeCellReader(rows, cols: cols, wraps: wraps);
    return scanner
        .scan(reader, [url, command])
        .where((m) => m.patternId == 'command')
        .toList();
  }

  group('in-block continuation join (#1042 recall)', () {
    test('a word-wrapped tool-result command joins with the consumed space '
        'reinserted (the 07-02 wrangler shape, head ends at cols-2)', () {
      // Real 07-02 trace shape: 58-col grid, head row content ends at col 56
      // (the TUI word-wrapped at its 2-col right margin, eating the space),
      // continuation at the deeper `⎿` band indent. No URL token anywhere —
      // the pre-#1042 joins all reject this seam.
      const row0 =
          r'  ⎿  $ command -v wrangler && wrangler --version || echo';
      const row1 = '     "wrangler: NOT on PATH"';
      expect(row0.length, 56, reason: 'head must end at cols-2 (58-col grid)');
      final cmds = commandsIn([row0, row1, ''], cols: 58);
      expect(cmds, hasLength(1));
      expect(
        cmds.single.payload,
        'command -v wrangler && wrangler --version || echo '
        '"wrangler: NOT on PATH"',
        reason: 'the word-wrap seam must reinsert the space the TUI consumed',
      );
      expect(cmds.single.maybeIncomplete, isFalse,
          reason: 'a blank row legitimately ends the block — fully joined');
    });

    test('a mid-token hard break AT the grid edge joins WITHOUT a space', () {
      // Head fills the grid exactly (end == cols): a hard break preserves
      // every char, so the halves glue back spaceless. Deeper-indent
      // continuation so no pre-#1042 rule claims the seam first.
      const row0 = r'⎿  $ echo /tmp/veryverylongpa';
      const row1 = '     th.txt';
      final cols = row0.length; // end == cols → hard break
      final cmds = commandsIn([row0, row1, ''], cols: cols);
      expect(cmds, hasLength(1));
      expect(cmds.single.payload, 'echo /tmp/veryverylongpath.txt');
      expect(cmds.single.maybeIncomplete, isFalse);
    });

    test('the join STOPS at a fresh prompt row (no evidence-free gluing)', () {
      // Head reaches the grid edge, but the next row is a new gutter-prompt
      // entry — a sibling command, not a continuation. The sibling sits at a
      // DEEPER indent so no pre-#1042 rule claims the seam (the same-margin
      // width join has its own, pre-existing semantics at the grid edge).
      const row0 = r'⎿  $ echo aaaaaaaaaaaaaaa';
      const row1 = '  56      ls -la /tmp';
      final cols = row0.length;
      final cmds = commandsIn([row0, row1], cols: cols);
      // The gutter row anchors as its OWN sibling command; the echo payload
      // must stay first-line-only and unmarked (a prompt successor is a
      // legitimate block end).
      final echo =
          cmds.where((m) => m.payload == 'echo aaaaaaaaaaaaaaa').toList();
      expect(echo, hasLength(1));
      expect(echo.single.maybeIncomplete, isFalse,
          reason: 'a fresh prompt successor is a legitimate block end');
    });

    test('a WEAK-prompt command never in-block joins (strong prompts only)',
        () {
      // Weak `$ ` prompt, lexicon+flag+operator (score 4) — detected, but the
      // liberal in-block join is reserved for STRONG prompts; the deeper
      // successor stays out of the payload.
      const row0 = r'  $ ls -la /tmp/some/dir | grep foobarbazqu';
      const row1 = '     ux.txt';
      final cols = row0.length; // reaches the grid edge
      final cmds = commandsIn([row0, row1, ''], cols: cols);
      expect(cmds, hasLength(1));
      expect(cmds.single.payload, 'ls -la /tmp/some/dir | grep foobarbazqu');
      expect(cmds.single.maybeIncomplete, isTrue,
          reason: 'the rejected boundary-reaching seam is exactly the '
              'honesty-valve case');
    });

    test('prose behind a strong prompt gets NO in-block join (no established '
        'command, no anchor)', () {
      const row0 = r'dev@fd-dev:~$ yes that looks right to me and more xy';
      const row1 = '     indented follow-up prose';
      final cols = row0.length;
      final cmds = commandsIn([row0, row1], cols: cols);
      expect(cmds, isEmpty,
          reason: 'body score < 2 → never established → never joined');
    });
  });

  group('maybeIncomplete truth table (#1042 honesty)', () {
    // The owner-trace shape: a strong `⎿  $ ` command whose successor is the
    // TUI's DEEPER-indented continuation band, with no boundary evidence at
    // the seam (a genuinely multi-line command — joining would corrupt).
    const ownerRow0 = r'  ⎿  $ echo "=== LXC 109 status on pve ==="';
    const ownerRow1 = r"     ssh pve 'pct status 109 2>&1; pct exec 109 --";
    const ownerCmd = 'echo "=== LXC 109 status on pve ==="';

    test('deeper-indent rejected successor → maybeIncomplete=true, payload '
        'stays the first line (the owner trace shape)', () {
      final cmds = commandsIn([ownerRow0, ownerRow1], cols: 55);
      expect(cmds, hasLength(1));
      expect(cmds.single.payload, ownerCmd,
          reason: 'seam has no boundary evidence — must NOT join (a real '
              'newline separates the lines; gluing corrupts the paste)');
      expect(cmds.single.maybeIncomplete, isTrue);
    });

    test('blank successor → false (the block legitimately ended)', () {
      final cmds = commandsIn([ownerRow0, '', ownerRow1], cols: 55);
      expect(cmds, hasLength(1));
      expect(cmds.single.maybeIncomplete, isFalse);
    });

    test('fresh prompt successor → false', () {
      final cmds =
          commandsIn([ownerRow0, r'dev@fd-dev:~$ git status'], cols: 55);
      final echo =
          cmds.where((m) => m.payload == ownerCmd).toList();
      expect(echo, hasLength(1));
      expect(echo.single.maybeIncomplete, isFalse);
    });

    test('new-block (bullet) successor → false', () {
      final cmds = commandsIn([ownerRow0, '     - a bullet item'], cols: 55);
      expect(cmds, hasLength(1));
      expect(cmds.single.maybeIncomplete, isFalse);
    });

    test('same-indent short-row successor (a bash command followed by its '
        'output) → false', () {
      final cmds = commandsIn(
        [r'dev@fd-dev:~$ ls -la /tmp', 'total 40'],
        cols: 55,
      );
      expect(cmds, hasLength(1));
      expect(cmds.single.maybeIncomplete, isFalse,
          reason: 'no boundary reach + no deeper band → nothing suggests a '
              'truncated wrap');
    });

    test('no successor row in the buffer → false (stay silent on unknowns)',
        () {
      final cmds = commandsIn([ownerRow0], cols: 55);
      expect(cmds, hasLength(1));
      expect(cmds.single.maybeIncomplete, isFalse);
    });

    test('a fully JOINED wrapped command (soft-wrap flag) → false', () {
      const row0 = r'dev@fd-dev:~$ curl -fsSL https://agent-hub.tailbe5094.ts.n';
      const row1 = 'et:8444/setup.sh | bash  -s reset';
      final cmds = commandsIn(
        [row0, row1, ''],
        cols: row0.length,
        wraps: [true, false, false],
      );
      expect(cmds, hasLength(1));
      expect(cmds.single.maybeIncomplete, isFalse);
    });
  });

  group('anchor plumbing', () {
    test('StructuredAnchor.fromMatch carries maybeIncomplete', () {
      final reader = _FakeCellReader([
        r'  ⎿  $ echo "=== LXC 109 status on pve ==="',
        r"     ssh pve 'pct status 109 2>&1; pct exec 109 --",
      ], cols: 55);
      final match = scanner
          .scan(reader, [command])
          .singleWhere((m) => m.patternId == 'command');
      expect(match.maybeIncomplete, isTrue);
      final anchor = StructuredAnchor.fromMatch(match);
      expect(anchor.maybeIncomplete, isTrue);
    });

    test('non-command matches never carry the flag', () {
      final reader = _FakeCellReader(
        ['see https://example.com/x for details', 'and more prose'],
        cols: 55,
      );
      final matches = scanner.scan(reader, [url]);
      expect(matches, isNotEmpty);
      for (final m in matches) {
        expect(m.maybeIncomplete, isFalse);
      }
    });
  });
}
