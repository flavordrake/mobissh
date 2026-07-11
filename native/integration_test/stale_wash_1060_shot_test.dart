// On-emulator acceptance for #1060 (owner P0) — the detection WASH must stay
// LOCKED to its tokens through a live-updating multi-anchor TUI (scroll AND
// in-place repaint), never floating over blank/moved cells, at the dialled-back
// intensity.
//
// Drives a churning TUI over SSH to test-sshd: a loop that home-cursors and
// reprints a BAND of anchor lines (URL + multi-segment paths) in place while
// periodically appending fresh lines (scroll) — the Claude-Code-on-phone shape
// the owner reported. Through the whole churn it asserts, against the REAL
// device paint stack, that NO capsule wash row sits over all-whitespace cells
// (the floating wash), then HOLDS the terminal for an external screenshot so the
// orchestrator reviews the wash-on-glyph placement + intensity.
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/stale_wash_1060_shot_test.dart

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'wash stays locked to its tokens through a churning multi-anchor TUI (#1060)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);
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

      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      final sessionId = entry!.id;

      TerminalController? controllerOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && controllerOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = controllerOf();
      expect(controller, isNotNull, reason: 'no ghostty controller for session');

      // Wait for a live shell prompt.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // A churning multi-anchor TUI: reprint a BAND of anchor rows IN PLACE
      // (home cursor, no clear-scroll) with \x1b[K erases between the redraw so
      // the cells under each anchor momentarily blank (the miss-grace trigger),
      // and every few frames append a fresh line so the band SCROLLS too. Two
      // multi-segment paths + one URL per band → several live washes at once.
      const script = r'''
u=https://docs.brew.sh/Tap-Trust
p1=/Applications/Xcode.app/Contents/Developer
p2=/usr/local/lib/python3.11/site-packages
i=0
while [ $i -lt 240 ]; do
  printf '\033[H'
  printf 'build %d fetch %s\033[K\n' "$i" "$u"
  printf 'sdk %s\033[K\n' "$p1"
  printf 'lib %s\033[K\n' "$p2"
  printf 'status running task %d ...\033[K\n' "$i"
  if [ $((i % 5)) -eq 0 ]; then printf 'log line %d appended\n' "$i"; fi
  i=$((i + 1))
  sleep 0.05
done
printf '\033[2J\033[H'
printf 'churn done — settled anchor washes:\n'
printf 'fetch %s\n' "$u"
printf 'sdk %s\n' "$p1"
printf 'lib %s\n' "$p2"
printf 'prompt> \n'
''';
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('$script\n')),
      );

      // Sample the REAL device paint state through the churn: no capsule wash
      // row may sit over all-whitespace cells.
      var floatSamples = 0;
      String worst = '';
      var sawWash = false;
      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        controller!.reportPaintedViewportOffset(controller.scrollbar.offset);
        final offset = controller.scrollbar.offset;
        final visible = controller.scrollbar.visible;
        for (final r in controller.highlights) {
          if (!r.capsule) continue;
          sawWash = true;
          for (var absRow = r.topRow; absRow <= r.bottomRow; absRow++) {
            final viewRow = absRow - offset;
            if (viewRow < 0 || viewRow >= visible) continue;
            final rowText = controller.visibleRowsText(viewRow, viewRow);
            final startCol = absRow == r.topRow ? r.topCol : 0;
            final endColRaw = absRow == r.bottomRow ? r.bottomCol : rowText.length;
            final s = startCol.clamp(0, rowText.length);
            final e = endColRaw.clamp(0, rowText.length);
            final slice = e > s ? rowText.substring(s, e) : '';
            if (slice.trim().isEmpty) {
              floatSamples++;
              worst = 'view=$viewRow payload=${r.payload}';
            }
          }
        }
      }

      expect(sawWash, isTrue,
          reason: 'no capsule wash ever painted during the churn — the TUI '
              'never surfaced a detected anchor (precondition failed)');
      expect(
        floatSamples,
        0,
        reason: 'a capsule wash floated over blank cells during the churning '
            'TUI — #1060 regression. worst: $worst',
      );
      debugPrint('STALEWASH1060 churn OK: sawWash=$sawWash floats=$floatSamples '
          'washSuppressedForGrace='
          '${controller!.detectionScanStats.washSuppressedForGrace}');

      // Screenshot HOLD: keep the settled anchor washes on screen for emu-shot.
      debugPrint('STALEWASH1060_SHOT_WINDOW_OPEN');
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint('STALEWASH1060_SHOT_WINDOW_CLOSED');
    },
  );
}
