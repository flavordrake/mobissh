@Tags(['ffi'])
library;

// REPLAY HARNESS scaffold + first regression fixture (#791).
//
// Proves the harness end-to-end against a REAL device-captured byte+scroll trace
// (NOT a synthetic printf — reference_grid_url_extraction §0): a real Claude-CLI
// tmux session recorded by the #790 in-app recorder, 55x28 grid, 114 raw byte
// chunks, saved by the server as a `*-bug-report.byte-trace.json` and dropped
// into `native/test/fixtures/replay/`.
//
// The libghostty VT parser loads under `flutter test` on the host VM (ffi tag),
// so `replayTrace(controller, trace)` runs in the fast gate on EVERY commit —
// no emulator, no SSH, no socket. This is the headless tier (#791): it pins the
// render-relevant state a scrollback bug (#789 scroll-stuck, #772 cursor block,
// #773 delayed paint, outline-drift) is about, so a reported repro becomes a
// permanent regression test.
//
// THE LOOP (see native/test/fixtures/replay/README.md):
//   captured `.byte-trace.json` → drop into fixtures → add a replay assertion
//   → fix at the source → the trace pins it forever.

import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The first real captured fixture: a recorder bug-report trace. 55x28 grid,
  // 114 byte events, 1 scroll event (resting offset 0). Pre-dates recorder-v2
  // (#793), so it carries no `sentSgrTrace` — the loader must tolerate that.
  const fixture = 'test/fixtures/replay/scroll_render_55x28.byte-trace.json';

  group('replay harness — captured bug-report byte-trace (#791)', () {
    test('loader parses the real fixture into ordered events + grid', () {
      final trace = loadByteTrace(fixture);

      // Grid is the captured size — the harness sizes the controller to it.
      expect(trace.cols, 55);
      expect(trace.rows, 28);

      // All 114 byte events present and timestamp-ascending after the loader's
      // sort (replay order is deterministic regardless of file order).
      expect(trace.byteTrace, hasLength(114));
      for (var i = 1; i < trace.byteTrace.length; i++) {
        expect(
          trace.byteTrace[i].tMs >= trace.byteTrace[i - 1].tMs,
          isTrue,
          reason: 'byteTrace must be ascending by tMs after load',
        );
      }
      expect(
        trace.byteTrace.every((e) => e.bytes.isNotEmpty),
        isTrue,
        reason: 'every chunk decodes to non-empty bytes',
      );

      // The single recorded scroll position.
      expect(trace.scrollTrace, hasLength(1));
      expect(trace.finalScrollOffset, 0);

      // Recorder-v2 SGR trace is absent in this fixture and tolerated.
      expect(trace.sentSgrTrace, isEmpty);
    });

    test(
      'replay ingests every chunk into a real controller without error and '
      'reaches the captured grid + a coherent, queryable scroll state',
      () async {
        final trace = loadByteTrace(fixture);
        final controller = await replayIntoNewController(trace);
        addTearDown(controller.dispose);

        // Grid matches the captured dimensions — the harness built the
        // controller to the trace's size.
        expect(controller.config.cols, 55);
        expect(controller.config.rows, 28);

        // REAL-DATA FINDING (not synthesized): this capture is a Claude-CLI TUI
        // that REPAINTS the PRIMARY screen in place (cursor positioning + line
        // erase), NOT a streaming log — so it produces NO scrollback even at
        // 261KB of bytes. scrollbackRows is therefore 0 here; the harness must
        // assert the state that is actually true, and a *different* fixture (a
        // streaming `cat`/`yes` log) would exercise the scrollback axis. This is
        // exactly the discovery the replay tier exists to surface.
        final bar = controller.scrollbar;
        expect(bar.visible, 28, reason: 'viewport shows the captured row count');
        expect(
          controller.scrollbackRows,
          0,
          reason: 'this repainting TUI capture overwrites rows in place — no '
              'scrollback (a streaming-log fixture would grow it)',
        );
        expect(
          bar.total,
          greaterThanOrEqualTo(bar.visible),
          reason: 'scrollbar total spans at least the viewport',
        );
        expect(
          controller.totalRows,
          greaterThanOrEqualTo(controller.config.rows),
          reason: 'total rows is at least the viewport',
        );

        // The replay applied the recorded resting offset (0). The offset is
        // honored and queryable — the exact axis #789 scroll-stuck lives on.
        // (A future widget tier replays the gesture stream for pixel-exact
        // mid-history offsets.)
        expect(
          bar.offset,
          0,
          reason: 'the captured resting scroll offset is honored, not snapped '
              'back — the #789 scroll-stuck axis',
        );
      },
    );

    test(
      'MEANINGFUL render assertion: the replayed grid carries the captured '
      'on-screen TUI content (not an empty/garbled buffer)',
      () async {
        final trace = loadByteTrace(fixture);
        final controller = await replayIntoNewController(trace);
        addTearDown(controller.dispose);

        // Extract the rendered grid content the way the selection/copy path
        // does. This is the render the bug is about: if the parser garbled the
        // stream, these distinctive tokens from the real captured session — all
        // present on the final repainted screen — would be absent.
        controller.selectAll();
        final rendered = controller.selectedText();

        expect(rendered, isNotEmpty);
        for (final token in const ['mobissh', 'scroll', 'cursor', 'stuck']) {
          expect(
            rendered,
            contains(token),
            reason: 'distinctive token "$token" from the REAL captured session '
                'must survive replay into the live grid',
          );
        }
      },
    );
  });
}
