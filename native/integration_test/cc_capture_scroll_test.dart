// On-emulator tmux control-mode (`-CC`) CAPTURE-PANE SCROLLBACK (#906 Stage 2).
//
// Control mode emits NO `%output` for copy-mode / scrollback scroll, so MobiSSH's
// local flterm scroll shows nothing back there — the grid only ever held the live
// tail. Real `-CC` clients (iTerm2) scroll by REQUESTING `capture-pane -S -E`
// history windows and drawing them. Stage 2 implements that: a vertical swipe
// (here driven through the same `proxy.sendTmuxScroll` IPC the gesture calls)
// advances the channel's scroll offset and captures the matching history window,
// which renders as the scrollback view.
//
// scripts/cc-scroll-setup.sh pre-fills the active pane with LINE_001..LINE_200 —
// far more than the viewport — so early line numbers live ONLY in scrollback. The
// test attaches (control mode ON), confirms the live tail (LINE_200) rendered but
// an early line (LINE_050) is NOT on screen, then scrolls BACK and asserts LINE_050
// arrives on the session's OUTPUT stream (`proxy.output`). That older number can
// ONLY have come from a scrollback capture-pane response.
//
// SCOPE / KNOWN BLOCKER (#906 Stage 2): this proves the IPC + capture-request +
// response BYTE path end-to-end — the scroll gesture reaches the host, the channel
// advances its offset and captures the right history window, and those bytes reach
// the terminal controller. It does NOT yet prove the on-GRID render: emulator
// screenshots show flterm still displaying the LIVE tail (cursor parked at the live
// prompt) even though `controller.write` received the captured rows. Rendering a
// captured history WINDOW into flterm's grid (vs. its own growing scrollback buffer
// + follow-to-bottom) is the unresolved structural blocker; a green here is a
// byte-path signal, NOT device proof (see feedback_device_run_not_headless_green).
//
// The orchestrator runs this FLAG-ON; the shipped build keeps the flag OFF.
//
// Setup (run FIRST): scripts/cc-scroll-setup.sh
// Run: scripts/native-connect-test.sh integration_test/cc_capture_scroll_test.dart

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
    '-CC scrolls the scrollback via capture-pane history (#906)',
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

      await container.read(tmuxControlModeProvider.notifier).set(true);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(tmuxControlMode, isTrue,
          reason: 'control-mode global must be ON before connect');

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

      // The attach capture renders the LIVE tail (LINE_200), not the early lines.
      var sawTail = false;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (rendered().contains('LINE_200')) {
          sawTail = true;
          break;
        }
      }
      expect(sawTail, isTrue,
          reason: 'the live tail (LINE_200) did not render on attach. '
              'Ensure scripts/cc-scroll-setup.sh ran. Saw: ${rendered()}');
      expect(rendered().contains('LINE_050'), isFalse,
          reason: 'LINE_050 is deep in scrollback — it must NOT be on the initial '
              'tail screen (else the scroll proof is vacuous). Saw: ${rendered()}');

      // Hold on the TAIL (before) — emu-shot capture point.
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      // SCROLL BACK. Each step advances the scroll offset ~20 lines and captures
      // a fresh history window; LINE_050 falls into the window after ~6 steps.
      var sawHistory = false;
      out.clear();
      for (var step = 0; step < 12 && !sawHistory; step++) {
        entry.proxy.sendTmuxScroll(20); // >0 = back into history
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (rendered().contains('LINE_050')) {
            sawHistory = true;
            break;
          }
        }
      }
      expect(sawHistory, isTrue,
          reason: 'scrolling back never delivered LINE_050 on proxy.output — the '
              'scrollback capture request/response byte path failed. '
              'Saw: ${rendered()}');

      // Hold on the SCROLLED-BACK state (after) — emu-shot capture point. NOTE:
      // the grid may still show the live tail (the Stage-2 on-grid blocker).
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      expect(find.byKey(const Key('session-menu-button')), findsOneWidget,
          reason: 'session torn down during the scrollback sequence');

      debugPrint('CC_CAPTURE_SCROLL: the scroll gesture drove a capture-pane '
          'history request and LINE_050 reached proxy.output (byte path OK). '
          'On-grid flterm render remains the open Stage-2 blocker.');
    },
  );
}
