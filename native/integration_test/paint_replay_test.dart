// paint_replay_test.dart — PAINT-STACK REPLAY HARNESS.
//
// Owner report 2026-07-08T00-51-01 (+118, plain Windows PowerShell over SSH,
// NO tmux, control mode OFF): "paint not happening again". The byte trace
// proved the PSReadLine redraw bytes reached the UI, the repaint telemetry
// showed `sync screen=primary rebuilt=34` for every chunk, and the screenshot
// still showed the pre-typing screen — the write→damage→paint pipeline lost
// content somewhere between controller.write and the glass.
//
// This test replays that RECORDED trace (embedded fixture, regenerate with
// scripts/paint-replay.sh) through the REAL production stack on the emulator:
// a live session's GhosttyTerminalView, bytes injected through the SAME
// proxy.output seam real SSH bytes use, real vsync, hardware GL. It then:
//
//   1. Derives the trace's expected FINAL VT state from a REFERENCE terminal
//      (a second, widget-less flterm controller at the captured grid size) —
//      no hardcoded strings, so ANY future bug-report trace replays the same
//      way (scripts/paint-replay.sh path/to/trace.json).
//   2. Asserts the UI grid ends up showing that final state (tail rows,
//      whitespace-stripped so a different emulator grid width only re-wraps).
//   3. Asserts the paint-stack BOUNDARY COUNTERS advanced across the replay:
//      bytesIn (write seam) → contentNotifies (terminal→render box) →
//      frameSyncs/paints (paint ran) and writeErrors == 0 — so a failure names
//      the broken layer instead of just "stale".
//   4. Repeats with a SYNTHETIC PSReadLine-style stress burst (rapid \x1b[K +
//      CR + cursor-hide/show + color redraws of one prompt row, then a final
//      marker) — the owner's workload shape, but denser.
//
// Run: scripts/paint-replay.sh                       (default owner trace)
//      scripts/paint-replay.sh some-trace.json       (any captured trace)
//      scripts/native-connect-test.sh integration_test/paint_replay_test.dart

import 'dart:convert';
import 'dart:math' as math;

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/diagnostics/paint_stats.dart';
import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import '../test/terminal/replay_trace_harness.dart';
import 'fixtures/paint_replay_fixture.dart';
import 'support/connect_helpers.dart';

/// Strip ALL whitespace so a marker survives re-wrapping at a different grid
/// width (the emulator's cols differ from the captured 66): a token split
/// across two rows re-joins once row text is concatenated and spaces dropped.
String squash(String s) => s.replaceAll(RegExp(r'\s+'), '');

/// The expected-final-state markers for [trace]: the squashed text of the last
/// [maxRows] non-empty viewport rows of a reference terminal that ingested the
/// whole trace. These are the NEWEST rows — exactly what a stale paint misses.
/// Trivial rows (< 5 chars squashed) are skipped as non-distinctive.
List<String> deriveFinalMarkers(BugReportTrace trace, {int maxRows = 8}) {
  final reference = TerminalController(
    config: TerminalConfig(cols: trace.cols, rows: trace.rows),
  );
  try {
    for (final e in trace.byteTrace) {
      reference.write(e.bytes);
    }
    final text = reference.visibleRowsText(0, trace.rows - 1);
    final rows = <String>[];
    for (final line in text.split('\n')) {
      final squashed = squash(line);
      if (squashed.length >= 5) rows.add(squashed);
    }
    return rows.length <= maxRows
        ? rows
        : rows.sublist(rows.length - maxRows);
  } finally {
    reference.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'replayed owner byte-trace + synthetic PSReadLine stress reach the glass',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Match the owner's failing configuration: detection ON (the report's
      // telemetry showed detActive=true — the #921 damage-competition class).
      container.read(detectionSettingsProvider.notifier).setEnabled(true);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MobisshApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      var connected = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        final accept = find.text('Trust + connect');
        if (accept.evaluate().isNotEmpty) {
          await tester.tap(accept.first);
          await tester.pump(const Duration(milliseconds: 300));
        }
        if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
          connected = true;
          break;
        }
      }
      expect(connected, isTrue, reason: 'never reached the terminal screen');

      final entry = container.read(sessionsProvider).active!;
      final sessionId = entry.id;
      TerminalController? ctrlOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && ctrlOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = ctrlOf()!;

      // Let the live shell prompt settle so its output doesn't interleave with
      // the replayed chunks.
      await tester.pump(const Duration(seconds: 2));

      final stats = paintStatsFor(sessionId);
      expect(stats, isNotNull, reason: 'paint stats not registered');

      String uiSquashed() {
        final rows = controller.scrollbar.visible;
        return squash(controller.visibleRowsText(0, rows > 0 ? rows - 1 : 0));
      }

      Map<String, Object?> snap() => stats!.snapshot();
      int counter(Map<String, Object?> s, String key) => (s[key] as int?) ?? 0;

      // ---- Phase 1: the OWNER's recorded trace ----------------------------
      final trace = parseByteTrace(paintReplayFixtureJson());
      final markers = deriveFinalMarkers(trace);
      expect(markers, isNotEmpty, reason: 'trace produced no final content');
      debugPrint('PAINTREPLAY markers=${markers.length} '
          'grid=${trace.cols}x${trace.rows} chunks=${trace.byteTrace.length}');

      final before = snap();
      var lastT = trace.byteTrace.isEmpty ? 0 : trace.byteTrace.first.tMs;
      for (final e in trace.byteTrace) {
        // Compress idle gaps (the trace holds a 7s typing pause) but keep
        // intra-burst order + a real inter-chunk beat so delivery, damage and
        // paint interleave the way they do live.
        final gap = (e.tMs - lastT).clamp(16, 250);
        lastT = e.tMs;
        entry.proxy.debugInjectOutput(e.bytes);
        await tester.pump(Duration(milliseconds: gap));
      }
      // Settle: output tick (80ms), detection re-scan debounce, a few frames.
      await tester.pump(const Duration(seconds: 1));

      final after = snap();
      debugPrint('PAINTREPLAY before=$before');
      debugPrint('PAINTREPLAY after=$after');

      // Boundary counters: name the layer on failure.
      expect(counter(after, 'writeErrors'), 0,
          reason: 'controller.write THREW during the replay — the write layer '
              'is broken (previously swallowed silently)');
      expect(
        counter(after, 'bytesInChunks') - counter(before, 'bytesInChunks'),
        greaterThanOrEqualTo(trace.byteTrace.length),
        reason: 'injected chunks never reached the controller.write seam',
      );
      expect(
        counter(after, 'contentNotifies'),
        greaterThan(counter(before, 'contentNotifies')),
        reason: 'terminal never notified the render box — damage layer broken',
      );
      expect(
        counter(after, 'paints'),
        greaterThan(counter(before, 'paints')),
        reason: 'render box paint() never ran after the bytes — paint '
            'scheduling broken (markNeedsPaint dropped?)',
      );
      expect(
        counter(after, 'frameSyncs'),
        greaterThan(counter(before, 'frameSyncs')),
        reason: 'no terminal-dirty frame sync after the bytes — the paint ran '
            'but never re-snapshotted the grid',
      );

      // The rendered-model assertion: every tail row of the trace's final VT
      // state must be on the UI grid. A stale paint (the owner's screenshot
      // froze BEFORE the typing) misses the error/prompt tail rows.
      final seen = uiSquashed();
      for (final marker in markers) {
        expect(
          seen.contains(marker),
          isTrue,
          reason: 'STALE GRID: final trace content "$marker" never appeared '
              'on the terminal. counters=$after '
              'gridTail=${seen.substring(math.max(0, seen.length - 300))}',
        );
      }

      // ---- Phase 2: synthetic PSReadLine-style stress ---------------------
      // The owner's workload shape, denser: rapid same-row redraws wrapped in
      // cursor-hide/show, with \x1b[K clears, CR returns and SGR color churn —
      // then a unique end marker. Injected back-to-back (pump every few chunks)
      // so damage/paint interleaving is as hostile as PSReadLine makes it.
      final stressBefore = snap();
      const marker = 'PAINTSTRESSEND91';
      final rand = math.Random(91);
      var pumpBudget = 0;
      for (var i = 0; i < 240; i++) {
        final word = 'cmd${rand.nextInt(9999)}';
        final chunk = i.isEven
            ? '\x1b[m\x1b[?25l'
            : '\x1b[93m\x1b[${(i % 20) + 5};1H\x1b[KPS C:\\stress> $word'
                '\x1b[m\x1b[?25h';
        entry.proxy.debugInjectOutput(
          Uint8List.fromList(utf8.encode(chunk)),
        );
        if (++pumpBudget >= 6) {
          pumpBudget = 0;
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      entry.proxy.debugInjectOutput(
        Uint8List.fromList(utf8.encode('\r\n$marker\r\n')),
      );
      await tester.pump(const Duration(seconds: 1));

      final stressAfter = snap();
      debugPrint('PAINTREPLAY stressAfter=$stressAfter');
      expect(counter(stressAfter, 'writeErrors'), 0,
          reason: 'controller.write threw during the stress burst');
      expect(
        counter(stressAfter, 'paints'),
        greaterThan(counter(stressBefore, 'paints')),
        reason: 'no paint during/after the stress burst',
      );
      final seenStress = uiSquashed();
      expect(
        seenStress.contains(marker),
        isTrue,
        reason: 'STALE GRID after PSReadLine-style stress: end marker never '
            'painted. counters=$stressAfter '
            'gridTail=${seenStress.substring(math.max(0, seenStress.length - 300))}',
      );
    },
  );
}
