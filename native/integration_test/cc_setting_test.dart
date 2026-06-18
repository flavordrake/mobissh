// On-emulator rollout test for the #913 tmux-control-mode SETTING (Part D).
//
// cc_render (#909) forces control mode ON with the TEST HOOK
// (`setTmuxControlModeForTest`). This test proves the SHIPPED ROLLOUT path: with
// the persisted user SETTING enabled (TmuxControlModeNotifier — the real Settings
// toggle source) and NO test-hook flip, a fresh connect to test-sshd (which has
// NO pre-existing tmux session) engages control mode via the attach-OR-create
// entry command (`tmux -CC new-session -A -s mobissh`) and the active window's
// %output renders to the grid. Reuses the cc_render render assertions.
//
// The orchestrator runs this. The shipped DEFAULT keeps the setting OFF, so the
// scrape path is unchanged unless the owner opts in here.
//
// Run: scripts/native-connect-test.sh integration_test/cc_setting_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/tmux_control_mode_setting.dart';
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // Start from a clean prefs store with the setting EXPLICITLY enabled — the
    // rollout path the owner takes in Settings. Crucially we do NOT call
    // setTmuxControlModeForTest: control mode must engage purely from the
    // persisted setting driving the per-isolate global.
    SharedPreferences.setMockInitialValues({tmuxControlModePrefKey: true});
    // Ensure the global is OFF before the notifier hydrates, so the assertion
    // below proves the SETTING (not a stale flag) flipped it.
    setTmuxControlModeForTest(false);
  });

  tearDown(() {
    setTmuxControlModeForTest(false);
  });

  testWidgets(
    'setting ON → fresh connect engages control mode (new-session -A) + renders '
    '(#913)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Read the notifier so it hydrates the stored `true` and syncs the global.
      final notifier = container.read(tmuxControlModeProvider.notifier);
      for (var i = 0; i < 20 && container.read(tmuxControlModeProvider) != true;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(container.read(tmuxControlModeProvider), isTrue,
          reason: 'persisted setting did not hydrate to ON');
      expect(tmuxControlMode, isTrue,
          reason: 'the notifier must sync the per-isolate global from the '
              'persisted setting so connect carries controlMode');
      // Belt-and-suspenders: a programmatic enable is idempotent.
      await notifier.set(true);

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
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      String rendered() => utf8.decode(out, allowMalformed: true);
      void send(String s) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(s)));

      // The host entered `tmux -CC new-session -A -s mobissh` automatically
      // (test-sshd has NO pre-existing tmux, so -A CREATED the session — a bare
      // attach would have failed "no sessions"). Wait for the initial window
      // paint: bytes only reach the grid if the control stream parsed + demuxed.
      var painted = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (out.isNotEmpty) {
          painted = true;
          break;
        }
      }
      expect(painted, isTrue,
          reason: 'control-mode grid received ZERO bytes — the SETTING did not '
              'engage control mode, or new-session -A failed on a tmux-less host');

      // Render a unique marker in the active window and confirm it paints — the
      // same render assertion cc_render uses, proving the demux works end-to-end.
      const marker = 'CC_SETTING_MARKER_913';
      var sawMarker = false;
      for (var attempt = 0; attempt < 6 && !sawMarker; attempt++) {
        send('send-keys -t :0 "echo $marker" Enter\n');
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          if (rendered().contains(marker)) {
            sawMarker = true;
            break;
          }
        }
      }
      expect(sawMarker, isTrue,
          reason: 'active window content did not render via control mode driven '
              'by the persisted SETTING. Saw: ${rendered()}');
      debugPrint(
        'CC_SETTING: persisted setting ON → control mode engaged on a '
        'tmux-less host via new-session -A; grid rendered the active window',
      );
    },
  );
}
