// tmux_window_switch_detection_test.dart — the #971 repro attempt: with DETECTION
// ON, switching tmux windows (Ctrl-b n) on the alt screen leaves the screen
// showing the PREVIOUS window ("cursor moves but screen not repainting"). The
// #900 renderer comment predicts a strict A/B/A/B stale alternation when an
// earlier paint's `update` consumed the switch's row damage — and detection adds
// exactly such a competing consumer (#921).
//
// This drives the trigger the earlier detect_paint_freeze_test MISSED (it toggled
// detection but never switched tmux windows) and asserts the RENDERED viewport
// (visibleRowsText) tracks the switched-to window across many switches. If the
// grid itself goes stale, this catches it here; the per-frame render telemetry
// (rebuilt/markedAll/detActive) is in the connect-log for the paint-phase view.
//
// Run: scripts/native-connect-test.sh integration_test/tmux_window_switch_detection_test.dart

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
    'DETECTION ON: switching tmux windows repaints the switched-to window',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Detection ON (default, but assert it explicitly — it's the trigger).
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

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'dead PTY — no shell output');

      void send(String cmd) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(cmd)));

      // tmux mouse on (the owner env: detection runs on the alt screen only with
      // mouse tracking — #834).
      send('tmux kill-server 2>/dev/null; tmux set -g mouse on \\; new -s ws\n');
      for (var i = 0; i < 40; i++) {
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
      expect(controller.activeScreen, TerminalScreen.alternate);

      Future<void> settle([int ticks = 14]) async {
        for (var i = 0; i < ticks; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      }

      bool rendered(String marker) {
        final rows = controller.scrollbar.visible;
        final text = controller.visibleRowsText(0, rows > 0 ? rows - 1 : 0);
        return text.contains(marker);
      }

      Future<bool> switchTo(int target, String want) async {
        send('tmux select-window -t $target\n');
        for (var i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (rendered(want)) return true;
        }
        return false;
      }

      // Build TWO windows, each with distinct content — with delays so each
      // command lands on the intended window (no send race).
      const m0 = 'WSWITCH_WINDOW_ZERO_ZZZZZZ';
      const m1 = 'WSWITCH_WINDOW_ONE_OOOOOO';
      send('clear; printf "$m0\\n"\n');
      await settle();
      send('tmux new-window\n');
      await settle();
      send('clear; printf "$m1\\n"\n');
      await settle();

      // CONTROL — detection OFF: switches MUST render the switched-to window.
      // If this fails, it's a setup/timing problem, NOT the #971 bug.
      container.read(detectionSettingsProvider.notifier).setEnabled(false);
      await settle();
      var ctrlFail = 0;
      for (var k = 0; k < 4; k++) {
        final t = k.isEven ? 0 : 1;
        final ok = await switchTo(t, t == 0 ? m0 : m1);
        debugPrint('WSWITCH detOFF k=$k target=$t rendered=$ok');
        if (!ok) ctrlFail++;
      }
      expect(ctrlFail, 0,
          reason: 'CONTROL (detection OFF): a window switch did not render '
              '($ctrlFail/4) — setup/timing issue, not the bug');

      // BUG — detection ON: the #971 repro. FIXED = every switch renders;
      // BROKEN = the switched-to window stays stale (previous window painted).
      container.read(detectionSettingsProvider.notifier).setEnabled(true);
      await settle();
      var bugFail = 0;
      for (var k = 0; k < 6; k++) {
        final t = k.isEven ? 0 : 1;
        final ok = await switchTo(t, t == 0 ? m0 : m1);
        debugPrint('WSWITCH detON k=$k target=$t rendered=$ok '
            'screen=${controller.activeScreen} grid=${controller.scrollbar.visible}');
        if (!ok) bugFail++;
      }
      expect(
        bugFail,
        0,
        reason:
            'DETECTION ON: $bugFail/6 tmux window switches showed the STALE '
            'previous window while detection-OFF rendered fine — #971 '
            'detection-triggered no-repaint on the alt screen.',
      );

      // #971 PIXEL check: grid tracks fine here (above), but the device symptom
      // is stale PAINTED pixels. Land on window 0 (m0) with detection ON, then
      // HOLD so the host can `emu-shot` the actual painted surface and compare
      // (m0 = fresh paint, m1 = pixel-stale). debugPrint marks the window so the
      // screenshot is unambiguous.
      await switchTo(0, m0);
      debugPrint('WSWITCH_HOLD on=window0 marker=$m0 (screenshot now)');
      await settle(80); // ~20s hold for the host screenshot
    },
  );
}
