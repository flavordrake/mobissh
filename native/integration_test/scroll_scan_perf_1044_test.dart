// On-emulator acceptance for #1044 (+ the #1046 chip-steady shape).
//
// PART 1 — the owner's scroll-lag case: a `seq 5000` flood with EVERY
// detection pattern ON plus a custom pattern, then real swipe-fling gestures.
// Measures, per drag frame: wall frame time (detection ON vs OFF) and the
// #1044 scan counters. The hard assertions are the DETERMINISTIC ones —
// during active dragging the detection layer performs ZERO scan work
// (rescans and prune re-reads both 0); frame-time numbers are REPORTED for
// the PR (emulator timing is too jittery to gate on).
//
// PART 2 — the #1046 shape: a shell loop repaints a line containing a
// detectable path at ~10Hz IN PLACE. Once its anchor is visible at a gutter
// row it must STAY visible at every subsequent sample (rows may change; a
// vanish = the flickering chip).
//
// Screenshot windows (orchestrator runs scripts/emu-shot.sh on the OPEN
// markers): PERF1044_FLING_WINDOW_OPEN, PERF1044_TUI_WINDOW_OPEN,
// PERF1044_SETTLED_WINDOW_OPEN.
//
// Run: scripts/native-connect-test.sh integration_test/scroll_scan_perf_1044_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

const _steadyToken = '/tmp/steady1046.txt';

/// Snapshot-diff of the #1044 counters.
Map<String, int> _statsDelta(Map<String, int> before, Map<String, int> now) {
  return {for (final k in now.keys) k: (now[k] ?? 0) - (before[k] ?? 0)};
}

int _p95(List<int> micros) {
  if (micros.isEmpty) return 0;
  final sorted = [...micros]..sort();
  return sorted[(sorted.length * 95 ~/ 100).clamp(0, sorted.length - 1)];
}

int _avg(List<int> micros) => micros.isEmpty
    ? 0
    : micros.reduce((a, b) => a + b) ~/ micros.length;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'seq-5000 fling: zero scan work while dragging (detection ON), frame '
    'times reported ON vs OFF; 10Hz TUI repaint keeps the chip steady '
    '(#1044/#1046)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);

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

      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      final sessionId = entry!.id;

      TerminalController? ctrlOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && ctrlOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = ctrlOf();
      expect(controller, isNotNull, reason: 'no ghostty controller');
      final c = controller!;

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      void send(String line) {
        entry.proxy.sendInput(Uint8List.fromList(utf8.encode(line)));
      }

      // #1035-shape custom pattern on top of the full default set. Registered
      // directly on the controller (the store-backed path is exercised by the
      // Detection Lab suite); it multiplies the per-line regex passes exactly
      // like a user-defined pattern does.
      c.registerTextPattern(
        TextPattern(id: 'custom.perf1044', regex: RegExp(r'PERFTOKEN-\d+')),
      );

      // The flood: 5000 lines with a detectable tail so anchors are LIVE in
      // the viewport when the fling starts.
      send('clear; seq 5000; '
          'echo tail https://example.com/perf1044 /etc/hosts PERFTOKEN-7\n');
      var tailSeen = false;
      for (var i = 0; i < 240; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (utf8
            .decode(out, allowMalformed: true)
            .contains('PERFTOKEN-7')) {
          tailSeen = true;
          break;
        }
      }
      expect(tailSeen, isTrue, reason: 'seq 5000 output never finished');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(
        c.anchors.any((a) => '${a.payload}'.contains('perf1044')),
        isTrue,
        reason: 'precondition: anchors live before the fling',
      );

      final termFinder = find.byKey(Key('ghostty-terminal-$sessionId'));
      expect(termFinder, findsOneWidget);
      final rect = tester.getRect(termFinder);
      final bodyX = rect.left + rect.width * 0.35;

      // One measured fling pass: [flings] downward-swipe gestures (content
      // scrolls up into history), recording wall time per pumped drag frame
      // and the scan-counter delta across ONLY the drag phases.
      Future<(List<int>, Map<String, int>)> flingPass(int flings) async {
        final frameMicros = <int>[];
        final before = c.detectionScanStats.snapshot();
        final dragDelta = <String, int>{};
        for (var s = 0; s < flings; s++) {
          final dragStart = c.detectionScanStats.snapshot();
          final g = await tester.startGesture(
            Offset(bodyX, rect.top + rect.height * 0.25),
          );
          for (var i = 1; i <= 8; i++) {
            await g.moveTo(
              Offset(bodyX, rect.top + rect.height * (0.25 + 0.08 * i)),
            );
            final sw = Stopwatch()..start();
            await tester.pump(const Duration(milliseconds: 8));
            frameMicros.add(sw.elapsedMicroseconds);
          }
          await g.up();
          final d =
              _statsDelta(dragStart, c.detectionScanStats.snapshot());
          for (final e in d.entries) {
            dragDelta[e.key] = (dragDelta[e.key] ?? 0) + e.value;
          }
          // Coast + settle (quiesce scans of newly-revealed rows are LEGAL
          // here — they are the settle reconcile, outside the drag window).
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
        }
        final total = _statsDelta(before, c.detectionScanStats.snapshot());
        debugPrint('PERF1044 pass total-delta=$total drag-delta=$dragDelta');
        return (frameMicros, dragDelta);
      }

      // ---- detection ON (full set + custom) ----
      debugPrint('PERF1044_FLING_WINDOW_OPEN');
      final (onFrames, onDrag) = await flingPass(6);
      debugPrint('PERF1044_FLING_WINDOW_CLOSED');
      debugPrint('PERF1044 ON  frames=${onFrames.length} '
          'avgUs=${_avg(onFrames)} p95Us=${_p95(onFrames)} '
          'dragScanDelta=$onDrag');

      expect(
        onDrag['rescans'] ?? 0,
        0,
        reason: 'NO rescan may run during an active drag — scans are content-'
            'driven and quiesce-deferred (#1044); got $onDrag',
      );
      expect(
        onDrag['pruneWindowScans'] ?? 0,
        0,
        reason: 'NO per-anchor prune re-read may run during a pure drag '
            '(#1044); got $onDrag',
      );

      // ---- detection OFF (baseline) ----
      await container
          .read(detectionSettingsProvider.notifier)
          .setEnabled(false);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(c.anchors, isEmpty, reason: 'detection OFF must clear anchors');
      final (offFrames, _) = await flingPass(6);
      debugPrint('PERF1044 OFF frames=${offFrames.length} '
          'avgUs=${_avg(offFrames)} p95Us=${_p95(offFrames)}');

      // Re-enable for part 2 (the app re-registers the default patterns).
      await container
          .read(detectionSettingsProvider.notifier)
          .setEnabled(true);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      // ---- PART 2: the #1046 shape — 10Hz in-place repaint, chip steady ----
      // The screen's top row is rewritten with the SAME detectable line every
      // 100ms for ~5s (cursor-home + clear-line, no newline → in place).
      send(r'clear; i=0; while [ $i -lt 50 ]; do '
          'printf \'\\033[H\\033[2K// note $_steadyToken steady\'; '
          r'i=$((i+1)); sleep 0.1; done'
          '\n');

      // Part 1 flung UP into the seq history and a `clear` does NOT yank a
      // scrolled-up viewport back down (correct terminal behavior). The #1046
      // scenario is a repainting status line the user is WATCHING — i.e. at the
      // bottom. Snap there so the repainting row is on-screen (and inside the
      // detection scan window); otherwise it repaints off-screen forever.
      c.scrollToBottom();
      await tester.pump(const Duration(milliseconds: 200));

      bool tokenVisible() {
        for (final a in c.anchors) {
          if (!'${a.payload}'.contains(_steadyToken)) continue;
          for (final r in a.ranges) {
            if (c.anchorGutterRow(r) != null) return true;
          }
        }
        return false;
      }

      // Wait for first detection (loop start + debounce / max-wait ceiling).
      var seen = false;
      for (var i = 0; i < 60 && !seen; i++) {
        c.scrollToBottom();
        await tester.pump(const Duration(milliseconds: 100));
        seen = tokenVisible();
        if (i % 4 == 0 || seen) {
          final tokenOnScreen = c.visibleRowsText(0, 43).contains(_steadyToken);
          debugPrint('PERF1044_PART2 i=$i seen=$seen '
              'isScrolling=${c.isScrolling} vpTop=${c.screenViewportTop} '
              'sb=${c.scrollbackRows} tokenOnScreen=$tokenOnScreen '
              'anchors=${c.anchors.length} '
              'stats=${c.detectionScanStats.snapshot()}');
        }
      }
      expect(seen, isTrue, reason: 'the repainted line never anchored');

      // Sample through the remainder of the repaint loop: once visible, the
      // anchor must NEVER vanish (a vanish is the #1046 blink).
      debugPrint('PERF1044_TUI_WINDOW_OPEN');
      var vanishes = 0;
      for (var i = 0; i < 40; i++) {
        c.scrollToBottom();
        await tester.pump(const Duration(milliseconds: 100));
        if (!tokenVisible()) vanishes++;
      }
      debugPrint('PERF1044_TUI_WINDOW_CLOSED vanishes=$vanishes');
      expect(
        vanishes,
        0,
        reason: 'the chip for a 10Hz in-place repainted line must be STEADY '
            '— $vanishes samples lost the anchor (#1046)',
      );

      // SETTLED screenshot window: repaint loop over, anchors at rest.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      debugPrint('PERF1044_SETTLED_WINDOW_OPEN');
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint('PERF1044_SETTLED_WINDOW_CLOSED');
    },
  );
}
