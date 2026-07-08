@Tags(['ffi'])
library;

// REPLAY regression for #996 — a URL inside a Claude Code TUI transcript is
// HARD-wrapped by the TUI itself with a hanging indent (continuation rows start
// indented under the content column, NOT at column 0 and NOT at the terminal
// edge). The #925/#928 wrap-join handles terminal soft-wraps and space-painted
// indents, but this TUI-authored hard break with hanging indent is a different
// join class: the anchor stops at the first-row fragment `https://agent-hub.t`
// so tap-copy truncates the URL.
//
// Owner device report on +121, byte-trace 2026-07-08T14-06-30 (158 chunks,
// grid 55x53): line 56 shows
//   curl -fsSL -m5 https://agent-hub.tailbe5094.ts.net:8444/motd.txt ...
// displayed across three rows; the bubble covers only `https://agent-hub.t`.

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fullUrl = 'https://agent-hub.tailbe5094.ts.net:8444/motd.txt';

  Future<TerminalController> replay() async {
    final trace = loadByteTrace(
      'test/fixtures/replay/claude_tui_hanging_indent_url_55x53.byte-trace.json',
    );
    final controller = TerminalController(
      config: TerminalConfig(cols: trace.cols, rows: trace.rows),
    );
    // Same three patterns, same order as the app (#767/#778).
    controller.registerTextPattern(TextPattern.osc8());
    controller.registerTextPattern(TextPattern.url());
    controller.registerTextPattern(TextPattern.path());
    await replayTrace(controller, trace);
    return controller;
  }

  group('REPLAY #996 — TUI hanging-indent hard-wrapped URL', () {
    test(
      'the agent-hub URL anchor carries the FULL URL, not the first-row '
      'fragment (tap-copy must not truncate at the TUI hard-wrap)',
      () async {
        final controller = await replay();
        addTearDown(controller.dispose);

        final hits = controller.anchors
            .where((a) => a.payload.toString().contains('agent-hub'))
            .toList();
        expect(
          hits,
          isNotEmpty,
          reason: 'the replayed grid contains the agent-hub URL — at least a '
              'fragment anchor must exist',
        );

        final payloads = hits.map((a) => a.payload.toString()).toList();
        expect(
          payloads,
          contains(fullUrl),
          reason: 'the anchor payload must be the FULL URL '
              '($fullUrl); the #996 bug truncates it at the TUI hanging-indent '
              'hard-wrap (`https://agent-hub.t`). Actual payloads: $payloads',
        );
      },
    );
  });
}
