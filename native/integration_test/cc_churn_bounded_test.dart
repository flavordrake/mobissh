// On-emulator tmux control-mode (`-CC`) CHURN BOUND — #916 (epic #906).
//
// The control-mode toggle (#906/#913, +64) CHURNED on the owner's real
// multi-client host: a `refresh-client -C 58,57 ↔ 58,34` resize STORM plus a
// connect→disconnect→reconnect LOOP (`tmux -CC new-session -A` issued twice).
// The emulator's single clean session never reproduced it, so this test forces
// the conditions that surface churn and asserts the #916 fixes hold END-TO-END:
//
//   1. NO reconnect loop: across the whole keyboard-toggle + window-switch
//      interaction the session NEVER leaves `connected` — i.e. exactly ONE clean
//      `-CC` attach per connect, no connect→disconnect→reconnect cycling. A loop
//      would log repeated connected→reconnecting→connected edges; we count them.
//   2. BOUNDED refresh-client -C: in control mode every settled size travels as a
//      single `refresh-client -C` on the trailing-edge settle, and a window-
//      switch redraw is COALESCED (host-side RefreshClientCoalescer, #916), so a
//      keyboard storm + a burst of switches produce a HANDFUL of writes, not a
//      per-animation-frame storm. We can't read the task-isolate coalescer's
//      sendCount cross-isolate on device, so we assert the OBSERVABLE proxy of a
//      tamed channel: the session survives the storm AND the grid keeps rendering
//      the active window (the channel was never torn down + re-attached). This
//      mirrors resize_storm_bounded_test's liveness contract for the -CC path.
//
// The orchestrator runs this FLAG-ON; the shipped build keeps the flag OFF.
//
// Run: scripts/native-connect-test.sh integration_test/cc_churn_bounded_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart'
    show GhosttyPointerGestureRouter;

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late bool prevFlag;
  setUp(() => prevFlag = setTmuxControlModeForTest(true));
  tearDown(() => setTmuxControlModeForTest(prevFlag));

  testWidgets(
    '-CC churn bound: single attach (no reconnect loop) + bounded '
    'refresh-client through a keyboard/window-switch storm (#916)',
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

      final entry = container.read(sessionsProvider).active!;
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      String rendered() => utf8.decode(out, allowMalformed: true);
      void send(String s) =>
          entry.proxy.sendInput(Uint8List.fromList(utf8.encode(s)));

      // Wait for the initial control-mode paint (the host auto-entered tmux -CC).
      var painted = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (out.isNotEmpty) {
          painted = true;
          break;
        }
      }
      expect(painted, isTrue,
          reason: 'control-mode grid received ZERO bytes — never attached');

      // Build a SECOND window so window-switch gestures have somewhere to go.
      send('new-window -n w1\n');
      await tester.pump(const Duration(milliseconds: 800));

      // ── Count reconnect-loop edges from HERE on. A clean session stays
      //    `connected` throughout; a loop cycles connected→reconnecting→connected
      //    (the owner's 13:28:55 / 13:29:04 / 13:29:15 churn). ──
      var leftConnectedCount = 0;
      var lastState = entry.proxy.data.state;
      final stateSub = entry.proxy.stream.listen((d) {
        if (lastState == SshSessionState.connected &&
            d.state != SshSessionState.connected) {
          leftConnectedCount += 1;
        }
        lastState = d.state;
      });
      addTearDown(stateSub.cancel);

      // ── The storm: toggle the keyboard + switch windows several rounds. Each
      //    keyboard show/hide animates the inset over many frames (a refresh-
      //    client burst pre-#916); each switch is a horizontal swipe (→ tmux
      //    next/previous-window) that also re-lays-out transiently. On the owner's
      //    multi-client host this drove the 58,57↔58,34 alternation. ──
      final router = find.byType(GhosttyPointerGestureRouter);
      expect(router, findsWidgets);
      final center = tester.getCenter(router.first);

      for (var round = 0; round < 4; round++) {
        await tester.tap(router.first, warnIfMissed: false);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
        await tester.dragFrom(center, const Offset(140, 0)); // → next-window
        await tester.pump(const Duration(milliseconds: 120));
        await tester.dragFrom(center, const Offset(-140, 0)); // ← previous-window
        await tester.pump(const Duration(milliseconds: 120));
        await SystemChannels.textInput.invokeMethod('TextInput.hide');
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
      }
      // Let the final size settle past the coalescer window (250ms each side).
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      // 1) NO reconnect loop: the session never churned out of `connected`.
      expect(leftConnectedCount, 0,
          reason: 'session churned $leftConnectedCount times out of connected — '
              'the -CC reconnect loop is NOT fixed (expected ONE clean attach)');
      expect(entry.proxy.data.state, SshSessionState.connected,
          reason: 'session not connected after the storm — it dropped/looped');

      // 2) BOUNDED / tamed: the session screen survived (channel not torn down +
      //    re-attached) and the grid still renders the active window. A storm that
      //    detached the client would have torn the screen down or starved the grid.
      expect(find.byKey(const Key('session-menu-button')), findsOneWidget,
          reason: 'session screen torn down during the storm — channel churned');

      out.clear();
      const liveMarker = 'CC_CHURN_LIVE_333';
      var stillRendering = false;
      for (var attempt = 0; attempt < 6 && !stillRendering; attempt++) {
        send('send-keys -t :0 "echo $liveMarker" Enter\n');
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          if (rendered().contains(liveMarker)) {
            stillRendering = true;
            break;
          }
        }
      }
      expect(stillRendering, isTrue,
          reason: 'grid stopped rendering after the storm — the control channel '
              'did not survive (a refresh-client storm / reconnect loop)');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
