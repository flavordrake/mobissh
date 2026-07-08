// #998 slice B — TextPattern.command: prompt-anchored command-line detection.
//
// Implements the issue's measured heuristic (design comment on #998, replayed
// against 15 real owner byte-traces / 379 logical lines with ZERO prose
// misfires):
//   * Stage 1 — a PROMPT ANCHOR is mandatory. STRONG prompts (bash
//     `user@host:path$ `, TUI line-number gutter, Claude `⎿  $ ` tool-result)
//     fire at body score >= 2. WEAK prompts (`❯ `, bare `$`/`#`/`%`) need
//     score >= 3 AND a command-lexicon hit. Bare `>` is excluded entirely
//     (PS2/blockquote FP risk).
//   * Stage 2 — body score: first token (or its basename) in the lexicon +2,
//     first token executable-shaped path +2, leading VAR=value assignment +1,
//     flag present +1, shell operator present +1.
//   * The lexicon is APP-SUPPLIED (pattern parameter) with the design's
//     curated default; the fork stays app-agnostic.
//   * Diff `+`/`-`-marked gutter rows are excluded (paste-corrupting joins).
//   * The pattern is BLOCK-tier with rangeGroup so the prompt stays
//     un-anchored ink and inner url/path span anchors coexist (slice A).
//
// Every prompt shape and every false-positive control below is REAL corpus
// text (owner byte-traces + live tmux sampling), not synthetic prose.

import 'package:flterm/src/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pure, headless [CellReader] built from per-row text + soft-wrap flags
/// (same seam as structured_text_tier_test.dart).
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
    TextPattern? pattern,
  }) {
    final reader = _FakeCellReader(rows, cols: cols, wraps: wraps);
    return scanner
        .scan(reader, [url, pattern ?? command])
        .where((m) => m.patternId == 'command')
        .toList();
  }

  group('TextPattern.command shape (#998 B)', () {
    test('is a block-tier pattern with a rangeGroup (prompt un-anchored)', () {
      expect(command.tier, TextTier.block);
      expect(command.rangeGroup, isNotNull);
      expect(command.id, 'command');
      expect(command.isOsc8Source, isFalse);
    });
  });

  group('STRONG prompt: bash user@host:path\$ (live tmux sample)', () {
    // Sampled live from the owner's tmux `main:3`: a soft-wrapped curl|bash
    // with a DOUBLE space in `bash  -s` — internal spacing must survive.
    const row0 = r'dev@fd-dev:~$ curl -fsSL https://agent-hub.tailbe5094.ts.n';
    const row1 = 'et:8444/setup.sh | bash  -s reset';
    const joined =
        'curl -fsSL https://agent-hub.tailbe5094.ts.net:8444/setup.sh '
        '| bash  -s reset';

    test('detects ONE command across the soft wrap, payload paste-exact', () {
      final cmds =
          commandsIn([row0, row1], cols: row0.length, wraps: [true, false]);
      expect(cmds, hasLength(1));
      expect(cmds.single.payload, joined,
          reason: 'prompt stripped, wrap joined, internal double space kept');
    });

    test('the prompt is NOT part of the anchor (rangeGroup geometry)', () {
      final cmds =
          commandsIn([row0, row1], cols: row0.length, wraps: [true, false]);
      final first = cmds.single.ranges.first;
      expect(first.startRow, 0);
      expect(first.startCol, row0.indexOf('curl'),
          reason: 'anchor starts at the command, after the prompt');
      expect(cmds.single.contains(0, 0), isFalse,
          reason: 'a tap on the prompt must not hit the command block');
    });

    test('the inner URL span anchor coexists with the command block', () {
      final reader = _FakeCellReader(
        [row0, row1],
        cols: row0.length,
        wraps: [true, false],
      );
      final matches = scanner.scan(reader, [url, command]);
      final urls = matches.where((m) => m.patternId == 'url');
      expect(urls, hasLength(1));
      expect(urls.single.payload,
          'https://agent-hub.tailbe5094.ts.net:8444/setup.sh');
      expect(matches.where((m) => m.patternId == 'command'), hasLength(1),
          reason: 'nesting: block + contained span both anchor');
    });

    test('an executable-shaped path as first token scores behind a strong '
        'prompt (no lexicon needed)', () {
      final cmds = commandsIn(
        [r'dev@fd-dev:~$ ./gradlew assembleRelease --no-daemon'],
        cols: 60,
      );
      expect(cmds, hasLength(1));
      expect(cmds.single.payload, './gradlew assembleRelease --no-daemon');
    });

    test('a leading VAR=value assignment contributes to the score', () {
      final cmds = commandsIn(
        [r'dev@fd-dev:~$ CC=clang make -j4'],
        cols: 40,
      );
      expect(cmds, hasLength(1));
      expect(cmds.single.payload, 'CC=clang make -j4',
          reason: 'assignments are part of the paste-able command');
    });

    test('prose behind a strong prompt does NOT anchor (score < 2)', () {
      final cmds = commandsIn(
        [r'dev@fd-dev:~$ yes that looks right to me'],
        cols: 45,
      );
      expect(cmds, isEmpty);
    });
  });

  group('STRONG prompt: TUI line-number gutter (14-06-30 class)', () {
    test('a numbered code-block command row anchors, gutter stripped', () {
      final cmds = commandsIn(
        ['56      curl -fsSL -m5 https://h.example/x 2>/dev/null'],
        cols: 60,
      );
      expect(cmds, hasLength(1));
      expect(cmds.single.payload,
          'curl -fsSL -m5 https://h.example/x 2>/dev/null');
    });

    test('shell history output anchors (history entries ARE commands)', () {
      final cmds = commandsIn(
        ['  501  git log --oneline -5'],
        cols: 40,
      );
      expect(cmds, hasLength(1));
      expect(cmds.single.payload, 'git log --oneline -5');
    });

    test('line-numbered PROSE stays silent (body score < 2)', () {
      final cmds = commandsIn(
        ['12  The quick brown fox jumps over the lazy dog'],
        cols: 55,
      );
      expect(cmds, isEmpty);
    });

    test('diff `+`-marked rows are EXCLUDED (the se+ssion corruption)', () {
      // Real 14-06-30 shape: the diff gutter `+` sits inside the wrap; a
      // naive join pastes corrupted text, so v1 skips diff-marked rows.
      final plusSingleSpace = commandsIn(
        ['53 +    echo "hub up done — restart the se'],
        cols: 55,
      );
      expect(plusSingleSpace, isEmpty);
      final plusWideGutter = commandsIn(
        ['53  +    echo "hub up done"'],
        cols: 55,
      );
      expect(plusWideGutter, isEmpty);
      final minusMarked = commandsIn(
        ['47  -    rm -rf /tmp/old-thing'],
        cols: 55,
      );
      expect(minusMarked, isEmpty);
    });
  });

  group(r'STRONG prompt: Claude tool-result `⎿  $ ` (07-02 class)', () {
    test('the real wrangler tool-result command anchors at score 2', () {
      // Real 07-02T14-12-13 row. Scores flag(+1) + operator(+1) = 2 — the
      // design's measured minimum behind a strong prompt (`command` is
      // deliberately NOT in the lexicon; the measured score was 2).
      final cmds = commandsIn(
        [r'⎿  $ command -v wrangler && wrangler --version || echo hi'],
        cols: 60,
      );
      expect(cmds, hasLength(1));
      expect(cmds.single.payload,
          'command -v wrangler && wrangler --version || echo hi');
    });

    test(r'a `⎿ ` tool-result WITHOUT the inner `$ ` prompt stays silent', () {
      final cmds = commandsIn(
        [r'⎿  pushed both branches to origin'],
        cols: 40,
      );
      expect(cmds, isEmpty);
    });
  });

  group('WEAK prompts need score >= 3 AND a lexicon hit', () {
    test(r'`$ ls -la | grep foo` anchors (lex + flag + operator)', () {
      final cmds = commandsIn([r'$ ls -la | grep foo'], cols: 30);
      expect(cmds, hasLength(1));
      expect(cmds.single.payload, 'ls -la | grep foo');
    });

    test(r'`% rm -rf /tmp/x` anchors (lex + flag)', () {
      final cmds = commandsIn([r'% rm -rf /tmp/x'], cols: 30);
      expect(cmds, hasLength(1));
      expect(cmds.single.payload, 'rm -rf /tmp/x');
    });

    test(r'`$ git status` does NOT anchor (score 2 < 3 — precision first)',
        () {
      final cmds = commandsIn([r'$ git status'], cols: 30);
      expect(cmds, isEmpty,
          reason: 'recall forgone knowingly: weak prompts need score >= 3');
    });

    test('`❯ go` (real Claude user-echo) does NOT anchor', () {
      final cmds = commandsIn(['❯ go'], cols: 20);
      expect(cmds, isEmpty);
    });

    test('`❯ /model` (real slash-command echo) does NOT anchor', () {
      final cmds = commandsIn(['❯ /model'], cols: 20);
      expect(cmds, isEmpty,
          reason: 'exec-path shape scores 2 but has no lexicon hit');
    });

    test('`❯` prose echo does NOT anchor', () {
      final cmds = commandsIn(
        ['❯ confirmed on device, switching + detection both work'],
        cols: 60,
      );
      expect(cmds, isEmpty);
    });

    test('a REAL pasted command behind `❯` anchors', () {
      final cmds = commandsIn(
        ['❯ curl -fsSL https://x.io/s.sh | bash'],
        cols: 45,
      );
      expect(cmds, hasLength(1));
      expect(cmds.single.payload, 'curl -fsSL https://x.io/s.sh | bash');
    });

    test(r'`$ ./gradlew --flag` does NOT anchor (path scores, no lexicon '
        'hit)', () {
      final cmds = commandsIn([r'$ scripts/build.sh --release | tee log'],
          cols: 45);
      expect(cmds, isEmpty,
          reason: 'weak prompts REQUIRE a lexicon hit, path shape is not one');
    });
  });

  group('bare `>` is excluded entirely', () {
    test('a command behind `> ` does NOT anchor (PS2/blockquote FP risk)', () {
      final cmds = commandsIn(['> curl -fsSL https://x.io | bash'], cols: 40);
      expect(cmds, isEmpty);
    });
  });

  group('unanchored lines never anchor (prompt is mandatory in v1)', () {
    test('tmux status-bar row (real: window named `bash`) stays silent', () {
      final cmds = commandsIn(['bash   Home-IT   fam'], cols: 30);
      expect(cmds, isEmpty);
    });

    test('prose starting with a script path AND containing a pipe stays '
        'silent', () {
      // Real 06-18 line: path-shaped first token + `|` operator — the exact
      // unanchored-tier FP the design measured (~8 misfires) and rejected.
      final cmds = commandsIn(
        [
          'scripts/play-login.sh {open|auto} is ready. Creds load from '
              '/home/dev/graft/.secrets/play.env (gitignored)',
        ],
        cols: 110,
      );
      expect(cmds, isEmpty);
    });

    test('a bare unanchored command stays silent (recall forgone in v1)', () {
      final cmds = commandsIn(
        [r'mkdir -p ~/.ssh && chmod 700 ~/.ssh'],
        cols: 45,
      );
      expect(cmds, isEmpty,
          reason: 'the design defers the unanchored tier to a later slice');
    });
  });

  group('the lexicon is APP-SUPPLIED', () {
    test('a custom lexicon changes what anchors', () {
      const line = r'$ frobnicate --fast | tee out.log';
      expect(commandsIn([line], cols: 40), isEmpty,
          reason: 'default lexicon has no `frobnicate` → weak gate fails');
      final custom = TextPattern.command(lexicon: ['frobnicate']);
      final cmds = commandsIn([line], cols: 40, pattern: custom);
      expect(cmds, hasLength(1));
      expect(cmds.single.payload, 'frobnicate --fast | tee out.log');
    });

    test('the design lexicon examples are in the default', () {
      for (final word in ['git', 'curl', 'ssh', 'docker', 'npm', 'flutter',
          'tmux', 'ls', 'grep', 'python3']) {
        expect(kDefaultCommandLexicon, contains(word));
      }
      expect(kDefaultCommandLexicon.length, greaterThanOrEqualTo(90),
          reason: 'the design specifies a ~100-word curated list');
    });

    test('lexicon matches the first token BASENAME too', () {
      final cmds = commandsIn([r'$ /usr/bin/rsync -avz src/ dst/'], cols: 40);
      expect(cmds, hasLength(1),
          reason: 'basename `rsync` is a lexicon hit (+2) + flag (+1)');
    });
  });
}
