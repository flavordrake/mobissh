// detect_paint_freeze_test.dart — enabling URL detection on a LIVE tmux alt
// screen must not freeze the repaint (device repros 2026-07-02: "can't scroll",
// "screen not repainting at all", "didn't detect URL after enabling, but did
// fail to paint"). Telemetry showed `repaint sync screen=alternate rebuilt=32`
// stuck after detection was enabled — the #921 repaint-root class (detection
// competes for the shared per-row damage handle) for the toggle-ON case.
//
// Repro shape: detection OFF → connect → tmux (mouse on) → stream output while
// on the alt screen → toggle detection ON mid-stream → keep streaming → assert
// the RENDERED grid (visibleRowsText, what's painted) keeps reflecting NEW
// output. A freeze = the grid stops advancing while bytes keep arriving.
//
// Run: scripts/native-connect-test.sh integration_test/detect_paint_freeze_test.dart

import 'dart:convert';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/foundation.dart';
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
    'enabling detection on a live tmux alt screen does NOT freeze the repaint',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Start with detection OFF so we can toggle it ON mid-session — the exact
      // device gesture ("turned on detect URLs").
      container.read(detectionSettingsProvider.notifier).setEnabled(false);

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

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      String seen() => utf8.decode(out, allowMalformed: true);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'dead PTY — no shell output');

      void send(String cmd) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(cmd)));

      // tmux mouse on (alt screen, the device environment). Re-send the mouse
      // enable periodically — under emulator load tmux can be slow to start, and
      // a single early `set -g mouse on` can land before the server is ready.
      send('tmux kill-server 2>/dev/null; tmux set -g mouse on \\; new -s p\n');
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (controller.mouseTracking != MouseTracking.none) break;
        if (i % 8 == 7) send('tmux set -g mouse on\n');
      }
      expect(controller.mouseTracking, isNot(MouseTracking.none),
          reason: 'tmux mouse mode never engaged');
      send('tmux set -g status off\n');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(controller.activeScreen, TerminalScreen.alternate,
          reason: 'expected the tmux alternate screen');

      // Whether a given marker line is currently RENDERED (painted grid), not
      // just present in the byte stream.
      bool rendered(String marker) {
        final rows = controller.scrollbar.visible;
        final text = controller.visibleRowsText(0, rows > 0 ? rows - 1 : 0);
        return text.contains(marker);
      }

      Future<bool> streamUntilRendered(String marker, {int maxPumps = 60}) async {
        for (var i = 0; i < maxPumps; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (rendered(marker)) return true;
        }
        return false;
      }

      // Baseline: with detection OFF, a streamed line paints.
      send('printf "PREON_MARKER_A\\n"\n');
      expect(await streamUntilRendered('PREON_MARKER_A'), isTrue,
          reason: 'baseline (detection off) — output not even painting');

      // THE GESTURE: enable detection while on the live alt screen.
      container.read(detectionSettingsProvider.notifier).setEnabled(true);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // Now stream MORE and require the rendered grid to advance. A freeze =
      // bytes arrive (seen() grows) but the painted grid never shows them.
      send('printf "POSTON_MARKER_B\\n"\n');
      final paintedAfterEnable = await streamUntilRendered('POSTON_MARKER_B');
      debugPrint('DETECTFREEZE seenHasB=${seen().contains("POSTON_MARKER_B")} '
          'renderedB=$paintedAfterEnable '
          'grid=${controller.scrollbar.visible}');
      expect(
        paintedAfterEnable,
        isTrue,
        reason:
            'PAINT FREEZE: after enabling detection on the live alt screen, new '
            'output reached the PTY but the rendered grid never showed it (#921 '
            'repaint-root, toggle-on case). seenHasB='
            '${seen().contains("POSTON_MARKER_B")}',
      );
    },
  );
}
