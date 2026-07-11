@Tags(['ffi'])
library;

// REPLAY coverage for #1042 — command anchors at unjoinable wraps.
//
// FIXTURE (the owner's +134 report, 2026-07-11T02-32-14, verbatim):
//   claude_tool_result_multiline_cmd_55x32 — a Claude tool-result showing a
//   genuinely MULTI-LINE command under one `⎿  $ ` prompt:
//     `  ⎿  $ echo "=== LXC 109 status on pve ==="`   (row ends at col 43)
//     `     ssh pve 'pct status 109 2>&1; …`          (deeper band, col 5)
//     … four more hard-wrapped rows, the last TUI-truncated with `…`.
//   OUTCOME for this trace: the anchor payload stays the FIRST line. The
//   `⎿  $ echo …` head ends at col 43 — nowhere near the 55-col grid edge or
//   any corroborated wrap column — so the seam onto the `ssh pve` band has NO
//   boundary evidence, and a REAL newline separates the lines (joining would
//   paste `…==="ssh pve…`, corrupted). This is the "genuinely unjoinable"
//   case: the fix is HONESTY — the anchor carries maybeIncomplete=true (its
//   successor is the block's deeper continuation band, rejected as a
//   continuation), so the chip/toast can say so instead of silently handing
//   over a partial command.
//
// RED→GREEN recall bonus on the EXISTING 07-02 fixture
// (claude_tool_result_cmd_58x32): its wrangler command IS a single logical
// line the TUI word-wrapped at col 56 (= cols-2) into the `⎿` band — before
// #1042 the anchor truncated at `|| echo`; the in-block continuation join now
// recovers the FULL command with the consumed space reinserted, and the blank
// successor row keeps it UNMARKED.

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

Future<TerminalController> _replay(String fixture) async {
  final trace = loadByteTrace('test/fixtures/replay/$fixture');
  final controller = TerminalController(
    config: TerminalConfig(cols: trace.cols, rows: trace.rows),
  );
  controller.registerTextPattern(TextPattern.osc8());
  controller.registerTextPattern(TextPattern.url());
  controller.registerTextPattern(TextPattern.path());
  controller.registerTextPattern(TextPattern.command());
  await replayTrace(controller, trace);
  return controller;
}

List<StructuredAnchor> _commandAnchors(TerminalController c) =>
    c.anchors.where((a) => a.patternId == 'command').toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('REPLAY #1042 — owner multi-line tool command (unjoinable seam)', () {
    const firstLine = 'echo "=== LXC 109 status on pve ==="';

    test('the anchor payload is the first command line, marked '
        'maybeIncomplete (honest partial copy)', () async {
      final controller = await _replay(
          'claude_tool_result_multiline_cmd_55x32.byte-trace.json');
      addTearDown(controller.dispose);

      final cmds = _commandAnchors(controller);
      expect(cmds, isNotEmpty,
          reason: r'the `⎿  $ echo …` row is a strong-prompt command');
      for (final a in cmds) {
        expect(a.payload, firstLine,
            reason: 'the seam onto the `ssh pve` band has no boundary '
                'evidence — it must NOT join (a real newline separates the '
                'lines; gluing corrupts the paste)');
        expect(a.maybeIncomplete, isTrue,
            reason: 'the deeper-indent successor was rejected as a '
                'continuation — the anchor must say the copy may be '
                'incomplete (#1042, the owner report)');
      }
    });
  });

  group(r'REPLAY #1042 — 07-02 `⎿  $ ` wrangler word-wrap (recall)', () {
    test('the word-wrapped wrangler command joins FULLY, space reinserted, '
        'unmarked', () async {
      final controller =
          await _replay('claude_tool_result_cmd_58x32.byte-trace.json');
      addTearDown(controller.dispose);

      final cmds = _commandAnchors(controller);
      expect(cmds, isNotEmpty);
      for (final a in cmds) {
        expect(
          a.payload,
          'command -v wrangler && wrangler --version || echo '
          '"wrangler: NOT on PATH"',
          reason: 'the head row ends at col 56 (= cols-2, the TUI word-wrap '
              'margin) and the continuation sits in the `⎿` band — the '
              'in-block join must recover the whole command and reinsert '
              'the space the wrap consumed',
        );
        expect(a.maybeIncomplete, isFalse,
            reason: 'a blank row ends the block — nothing was left behind');
      }
    });
  });
}
