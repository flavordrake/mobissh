// On-emulator VISUAL smoke for the #989 gutter mark restyle.
//
// Connects to test-sshd, prints one URL line and one absolute-path line, waits
// until BOTH are detected (a `url` anchor and a `path` anchor), then HOLDS the
// terminal on screen for a screenshot window: the orchestrator runs
// `scripts/emu-shot.sh gutter-restyle` during the hold and reviews the PNG —
// the chip marks must read as physical tappable buttons at phone density (the
// screenshot IS the test; the geometry/contrast minimums are asserted headlessly
// in test/ui/ghostty_gutter_layer_test.dart).
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/gutter_mark_restyle_shot_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'gutter marks (URL + path) render for screenshot review (#989)',
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

      const url = 'https://example.com/gutter/restyle';
      const path = '/etc/hosts';
      entry.proxy.sendInput(
        Uint8List.fromList(
          utf8.encode('echo VISIT989 $url; echo CONFIG989 $path\n'),
        ),
      );

      bool bothDetected() =>
          controller!.anchors.any(
            (a) => a.patternId == 'url' && a.payload == url,
          ) &&
          controller.anchors.any((a) => a.patternId == 'path');
      for (var i = 0; i < 40 && !bothDetected(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        bothDetected(),
        isTrue,
        reason: 'URL + path anchors never both appeared (#989 shot precondition)',
      );

      // Screenshot HOLD: keep the marks on screen for the external emu-shot.
      debugPrint('GUTTER989_SHOT_WINDOW_OPEN');
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint('GUTTER989_SHOT_WINDOW_CLOSED');
    },
  );
}
