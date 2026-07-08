@Tags(['ffi'])
library;

// REPLAY coverage for #998 slice B — TextPattern.command over REAL owner
// byte-traces (no synthetic examples; see the design comment on #998).
//
// DETECTIONS (the design's two true positives over the 15-trace corpus):
//   * claude_tui_hanging_indent_url_55x53 — the canonical 14-06-30 curl:
//     `      56      curl -fsSL -m5 https://agent-hub…` hard-wrapped by the
//     Claude TUI across three rows with a hanging indent (the #996 join
//     class). Must detect as ONE block-tier command anchor whose payload is
//     the exact paste-able command (prompt/gutter stripped, wrap joined,
//     internal quoting preserved) — with the inner URL span anchor intact
//     and tier-aware hit-testing (tap URL → URL; tier:block → command).
//   * claude_tool_result_cmd_58x32 — 07-02T14-12-13, the `⎿  $ ` Claude
//     tool-result inner prompt (the design's measured score-2 minimum).
//
// CONTROLS (the design's false-positive bait, all real, ZERO command
// anchors expected):
//   * claude_prompt_echo_go_58x32    — 07-05T22-48-19, `❯ go` user echo.
//   * claude_prompt_echo_model_55x48 — 06-10T12-14-16, `❯ /model` echo.
//   * scripts_prose_pipe_58x34       — 06-18T00-35-43, prose that STARTS
//     with `scripts/play-login.sh` AND contains `|` (the unanchored-tier FP
//     the design measured and rejected).
//   * tmux_status_bar_55x32          — 07-01T13-30-39, status-bar rows with
//     a window literally named `bash` (kills any lexicon-without-prompt
//     rule).

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

/// Replay [fixture] with the app's span patterns PLUS the command pattern
/// (same order as the app for the span set, #767/#778; command opt-in #998).
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

  group('REPLAY #998 B — canonical 14-06-30 curl (hanging-indent TUI)', () {
    const expectedCommand =
        'curl -fsSL -m5 https://agent-hub.tailbe5094.ts.net:8444/motd.txt '
        '2>/dev/null || echo "hub: motd unreachable" >&2';
    const innerUrl = 'https://agent-hub.tailbe5094.ts.net:8444/motd.txt';

    Future<TerminalController> replayCurl() =>
        _replay('claude_tui_hanging_indent_url_55x53.byte-trace.json');

    test('detects the wrapped curl as ONE command anchor, payload '
        'paste-exact (quotes, 2>/dev/null, the >/&2 row split)', () async {
      final controller = await replayCurl();
      addTearDown(controller.dispose);

      final cmds = _commandAnchors(controller);
      expect(cmds, isNotEmpty,
          reason: 'the 14-06-30 curl is the canonical detection');
      final payloads = {for (final a in cmds) a.payload.toString()};
      expect(payloads, {expectedCommand},
          reason: 'EVERY command anchor in this trace is the curl line, '
              'joined paste-exact with the prompt/gutter stripped');
    });

    test('the gutter prompt stays un-anchored ink (rangeGroup)', () async {
      final controller = await replayCurl();
      addTearDown(controller.dispose);

      for (final a in _commandAnchors(controller)) {
        final first = a.ranges.first;
        expect(first.startCol, greaterThan(8),
            reason: 'the `      56      ` line-number gutter (cols 0..13) '
                'must not be part of the command anchor');
      }
    });

    test('the inner URL span anchor coexists inside the command block',
        () async {
      final controller = await replayCurl();
      addTearDown(controller.dispose);

      final urls = controller.anchors
          .where((a) =>
              a.patternId == 'url' && a.payload.toString() == innerUrl)
          .toList();
      expect(urls, isNotEmpty,
          reason: 'the URL inside the command keeps its own span anchor');
    });

    test('tier-aware hit-test: a URL cell resolves the SPAN match by '
        'default and the command via tier:block', () async {
      final controller = await replayCurl();
      addTearDown(controller.dispose);

      // Find a URL anchor cell that sits INSIDE a command anchor.
      final urls = controller.anchors.where((a) =>
          a.patternId == 'url' && a.payload.toString() == innerUrl);
      final cmds = _commandAnchors(controller);
      var checked = 0;
      for (final u in urls) {
        final r = u.ranges.first;
        final covering =
            cmds.where((c) => c.contains(r.startRow, r.startCol));
        if (covering.isEmpty) continue;
        final viewRow = r.startRow - controller.screenViewportTop;
        final span =
            controller.matchAt(row: viewRow, col: r.startCol);
        expect(span, isNotNull);
        expect(span!.tier, TextTier.span,
            reason: 'an inline tap NEVER routes to the command block');
        expect(span.payload, innerUrl);
        final block = controller.matchAt(
            row: viewRow, col: r.startCol, tier: TextTier.block);
        expect(block, isNotNull,
            reason: 'the command stays resolvable via tier:block');
        expect(block!.patternId, 'command');
        expect(block.payload, expectedCommand);
        checked++;
      }
      expect(checked, greaterThan(0),
          reason: 'at least one URL cell sits inside a command anchor');
    });
  });

  group(r'REPLAY #998 B — 07-02 `⎿  $ ` tool-result command', () {
    test('the wrangler tool-result line anchors, prompt stripped', () async {
      final controller =
          await _replay('claude_tool_result_cmd_58x32.byte-trace.json');
      addTearDown(controller.dispose);

      final cmds = _commandAnchors(controller);
      expect(cmds, isNotEmpty,
          reason: r'the `⎿  $ command -v wrangler…` row is a real command '
              'behind a strong prompt (design score 2)');
      for (final a in cmds) {
        final payload = a.payload.toString();
        expect(payload, startsWith('command -v wrangler'),
            reason: 'every command anchor in this trace is the wrangler '
                'line; the prompt is stripped. Actual: $payload');
        expect(payload, isNot(contains('⎿')));
      }
    });
  });

  group('REPLAY #998 B — controls: ZERO command anchors', () {
    for (final (fixture, label) in [
      ('claude_prompt_echo_go_58x32.byte-trace.json', '`❯ go` user echo'),
      (
        'claude_prompt_echo_model_55x48.byte-trace.json',
        '`❯ /model` slash-command echo'
      ),
      (
        'scripts_prose_pipe_58x34.byte-trace.json',
        'prose starting with scripts/play-login.sh containing `|`'
      ),
      (
        'tmux_status_bar_55x32.byte-trace.json',
        'tmux status bar with a window named `bash`'
      ),
    ]) {
      test('$label produces NO command anchors', () async {
        final controller = await _replay(fixture);
        addTearDown(controller.dispose);

        final cmds = _commandAnchors(controller);
        expect(
          cmds.map((a) => a.payload).toList(),
          isEmpty,
          reason: 'control trace $fixture must not anchor any command '
              '(precision-first: a bubbled paragraph is noise)',
        );
      });
    }
  });
}
