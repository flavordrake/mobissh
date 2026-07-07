// On-emulator tmux control-mode (`-CC`) CAPTURE-PANE ATTACH-RENDER (#906 Stage 1).
//
// The gap: `tmux -CC attach` pushes NO initial screen (only `%session-changed`),
// and MobiSSH's `-CC` path rendered only live `%output` — so an idle attached
// pane stayed BLANK until the next byte. Real `-CC` clients (iTerm2) fix this by
// REQUESTING `capture-pane` on attach and drawing the response themselves. Stage 1
// implements that: on `%session-changed` the channel requests `capture-pane -p -e
// -J`, correlates the `%begin…%end` response by FIFO order, and renders it (clear
// + write) into flterm.
//
// This test PROVES the capture render END-TO-END: scripts/cc-capture-setup.sh
// pre-creates a PERSISTENT `main` session whose active pane shows a STATIC marker
// (`CAPTURE_SCREEN_MARKER_XYZ`) on an otherwise-quiet screen. The app then attaches
// with control mode ON and — WITHOUT sending a single keystroke — the marker must
// appear in the rendered output. Because the pane produces no live `%output`, the
// marker can ONLY have reached the grid via the capture-pane render. On the OLD
// behaviour (no capture) the grid stays blank and this test is RED.
//
// The orchestrator runs this FLAG-ON; the shipped build keeps the flag OFF.
//
// Setup (run FIRST): scripts/cc-capture-setup.sh
// Run: scripts/native-connect-test.sh integration_test/cc_capture_attach_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/tmux_control_mode_setting.dart';
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late bool prevFlag;
  setUp(() => prevFlag = setTmuxControlModeForTest(true));
  tearDown(() => setTmuxControlModeForTest(prevFlag));

  testWidgets(
    '-CC renders the attached pane via capture-pane, no new output (#906)',
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

      // Enable control mode THROUGH the provider (the notifier's async hydrate
      // resets the raw global, so the setUp flag alone races it) — set(true)
      // persists + syncs the global so connect carries controlMode=true.
      await container.read(tmuxControlModeProvider.notifier).set(true);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(tmuxControlMode, isTrue,
          reason: 'control-mode global must be ON before connect');

      // Control mode ON → entry is `tmux -CC attach …`, grabbing the PRE-EXISTING
      // `main` (created by scripts/cc-capture-setup.sh).
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

      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      String rendered() => utf8.decode(out, allowMalformed: true);

      // THE ASSERTION: without sending ANY input, the pre-existing pane's static
      // screen must render — proof that capture-pane painted the attach. The pane
      // is idle (no live %output), so the marker can arrive ONLY via the capture.
      var sawMarker = false;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (rendered().contains('CAPTURE_SCREEN_MARKER_XYZ')) {
          sawMarker = true;
          break;
        }
      }
      expect(sawMarker, isTrue,
          reason: 'the attached pane did NOT render via capture-pane — the grid '
              'stayed blank on an idle attach (Stage-1 regression). '
              'Ensure scripts/cc-capture-setup.sh ran. Saw: ${rendered()}');

      // Hold on the rendered state (emu-shot capture point).
      await tester.pump(const Duration(seconds: 3));

      expect(find.byKey(const Key('session-menu-button')), findsOneWidget,
          reason: 'session torn down during the capture-attach render');

      debugPrint('CC_CAPTURE_ATTACH: capture-pane rendered the idle attached '
          'pane (CAPTURE_SCREEN_MARKER_XYZ) with zero new %output');
    },
  );
}
