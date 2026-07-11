@Tags(['ffi'])
library;

// #1046 — the flickering gutter chip, replayed from the owner's device trace.
//
// Owner report (+135, 2026-07-11T15-58-31): a comment line at the top of a
// Claude-CLI TUI carried a gutter chip that FLICKERED — the anchor was being
// dropped and re-created cycle after cycle as the TUI repainted. Root (#1044):
// every full `_rescanDetections` REPLACED `_detectionMatches` wholesale with
// fresh instances and always fired the decoration notify, and mid-repaint
// prune/rescan interleavings could evict-then-rediscover an unchanged line.
//
// This test replays the report's byte-trace VERBATIM (fixture copied from
// test-results/uploads/2026-07-11T15-58-31-bug-report.byte-trace.json)
// through the real widget tier with the device's pattern set, sampling the
// anchor set on every frame. THE assertion: once a payload's anchor is
// present, it never blinks — no present → absent → present transition across
// the whole replay (an anchor may appear late [discovery] or die for good
// [content truly gone], but it must never oscillate). Post-#1044 the
// identity-preserving reconcile + notify suppression make an unchanged
// repaint invisible to the gutter, so the chip renders steady.

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

const _fixture =
    'test/fixtures/replay/tui_comment_chip_flicker_62x36.byte-trace.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'replaying the #1046 trace: no anchor ever blinks (present → absent → '
    'present) across the full TUI repaint cycle',
    (tester) async {
      final trace = loadByteTrace(_fixture);
      expect(trace.cols, 62);
      expect(trace.rows, 36);

      final controller = TerminalController(
        config: TerminalConfig(cols: trace.cols, rows: trace.rows),
      );
      addTearDown(controller.dispose);
      // The device pattern set (all detection types ON, as in the report).
      controller.registerTextPattern(TextPattern.osc8());
      controller.registerTextPattern(TextPattern.url());
      controller.registerTextPattern(TextPattern.path());
      controller.registerTextPattern(TextPattern.relativePath());
      controller.registerTextPattern(TextPattern.command());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 620,
              child: TerminalView(
                controller: controller,
                autofocus: false,
                theme: TerminalTheme.dark().copyWith(fontSize: 14),
                padding: const EdgeInsets.all(4),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Per-payload presence tracking, sampled once per FRAME (the visible
      // granularity — an evict+re-add inside one frame never paints).
      final everPresent = <String>{};
      final present = <String>{};
      final blinked = <String>{};

      void sample() {
        final now = <String>{
          for (final a in controller.anchors) '${a.patternId}|${a.payload}',
        };
        for (final key in now) {
          if (everPresent.contains(key) && !present.contains(key)) {
            blinked.add(key); // it was here, went away, and came BACK
          }
          everPresent.add(key);
        }
        present
          ..clear()
          ..addAll(now);
      }

      // Replay with the CAPTURED cadence (gaps clamped to keep the fake
      // clock moving frame-by-frame), sampling after every pumped frame so
      // the debounce/settle timers interleave exactly as on device.
      var lastT = trace.byteTrace.first.tMs;
      for (final e in trace.byteTrace) {
        var gap = e.tMs - lastT;
        lastT = e.tMs;
        if (gap < 0) gap = 0;
        if (gap > 300) gap = 300;
        // Advance the clock in <=50ms slices so debounce (120ms) and settle
        // (140ms) timers fire BETWEEN chunks like they did on device, and
        // sample each slice.
        while (gap > 0) {
          final slice = gap > 50 ? 50 : gap;
          await tester.pump(Duration(milliseconds: slice));
          sample();
          gap -= slice;
        }
        controller.write(lfToCrlf(e.bytes));
        await tester.pump();
        sample();
      }
      // Final quiesce.
      await tester.pump(const Duration(milliseconds: 400));
      sample();
      await tester.pump(const Duration(milliseconds: 200));
      sample();

      expect(
        everPresent,
        isNotEmpty,
        reason: 'sanity: the trace produced detection anchors',
      );
      expect(
        blinked,
        isEmpty,
        reason: 'no anchor may blink (present → absent → present) during a '
            'TUI repaint — a chip must render STABLY or not at all (#1046). '
            'Blinked: $blinked',
      );
    },
  );
}
