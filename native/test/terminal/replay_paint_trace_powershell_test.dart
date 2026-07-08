@Tags(['ffi'])
library;

// Headless MODEL tier of the paint replay harness (owner report
// 2026-07-08T00-51-01, "paint not happening again" — plain PowerShell over
// SSH, no tmux, control mode off).
//
// Replays the captured PSReadLine byte trace through a real widget-less flterm
// controller and asserts the final VT MODEL state: the typed command's error
// output + the fresh prompt must be present in the visible grid. This tier is
// the bisection anchor for the on-device tier
// (integration_test/paint_replay_test.dart):
//
//   headless GREEN + emulator STALE  → the bug is in the RENDER path
//                                      (damage → frame sync → paint), not VT;
//   headless RED                     → the VT/parser layer itself mishandles
//                                      the byte stream.
//
// Run (ffi-tagged, host VM): part of scripts/native-fast-gate.sh.

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fixture =
      'test/fixtures/replay/2026-07-08T00-51-01-paint-not-happening.byte-trace.json';

  test('PowerShell PSReadLine trace: final VT state carries the tail content',
      () {
    final trace = loadByteTrace(fixture);
    expect(trace.cols, 66);
    expect(trace.rows, 34);
    expect(trace.byteTrace, isNotEmpty);

    // Verbatim replay: the recorded bytes are raw post-PTY CRLF already, so no
    // LF→CRLF rewrite — the model must see EXACTLY what the device saw.
    final controller = TerminalController(
      config: TerminalConfig(cols: trace.cols, rows: trace.rows),
    );
    addTearDown(controller.dispose);
    for (final e in trace.byteTrace) {
      controller.write(e.bytes);
    }

    final text = controller.visibleRowsText(0, trace.rows - 1);
    final squashed = text.replaceAll(RegExp(r'\s+'), '');

    // The trace's last chunks: the "tmux a" error + a fresh prompt. The owner's
    // stale screenshot showed NONE of these (frozen at the banner).
    expect(squashed, contains("tmux:Theterm'tmux'isnotrecognized"),
        reason: 'error headline missing from the final VT state');
    expect(squashed, contains('CommandNotFoundException'),
        reason: 'error detail missing from the final VT state');
    // Two prompts: the banner one AND the fresh post-error one.
    final prompts = r'PSC:\Users\retur>'.allMatches(squashed).length;
    expect(prompts, greaterThanOrEqualTo(2),
        reason: 'fresh prompt after the error missing — grid stuck pre-typing');
  });
}
