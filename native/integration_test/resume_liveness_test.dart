// On-emulator resume liveness test (#737).
//
// Daily-driver bug: wake the phone from sleep → ALL sessions frozen. During
// Doze the SSH TCP socket dies HALF-OPEN and the 15s keepalive timer is frozen,
// so on resume the session is still `connected` with a dead socket. The old
// resume handler only `rebind()`d (re-subscribe + re-emit the cached snapshot);
// it never verified liveness, so input flowed into a dead pipe and no output
// returned — a live-looking but frozen terminal.
//
// The fix wires an ACTIVE liveness probe on resume: the UI sends a resume-probe
// command and the task side pings each `connected` session with a short
// timeout. A dead socket is declared dead (→ softDisconnected → reconnect)
// instead of "never"; a LIVE socket stays connected.
//
// SEAM / coverage boundary (documented per #589):
//   - The DEAD half-open-socket → reconnect logic is covered DETERMINISTICALLY
//     in test/ssh/resume_liveness_probe_test.dart (probe times out → reconnect)
//     and test/services/resume_probe_host_test.dart (resumeProbe routes to the
//     hosted controller's probeLiveness). True Doze half-open death cannot be
//     reproduced on the emulator without OS-level Doze, so those seams stand in
//     for it.
//   - THIS emulator test proves the END-TO-END resume path against a LIVE sshd:
//     after a real connect + shell, a simulated `AppLifecycleState.resumed`
//     event (didChangeAppLifecycleState) must NOT break the live session — the
//     terminal stays connected and input still echoes (no spurious reconnect,
//     no freeze). It is the regression guard that the probe doesn't kill good
//     sessions on every wake.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'resume of a LIVE session stays connected + input still echoes (#737)',
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

      // Connect to the emulator-local sshd and prove a live shell.
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
        if (find
            .byKey(const Key('session-menu-button'))
            .evaluate()
            .isNotEmpty) {
          connected = true;
          break;
        }
      }
      expect(
        connected,
        isTrue,
        reason: 'initial connect did not reach a shell',
      );

      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull);

      // Prove the first shell streams bytes.
      final out = <int>[];
      final sub = entry!.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      var gotBytes = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (out.isNotEmpty) {
          gotBytes = true;
          break;
        }
      }
      expect(gotBytes, isTrue, reason: 'no pre-resume shell bytes');

      // Simulate a background → resume cycle (the wake the user does each
      // morning). The lifecycle observer mirrors these into lifecycleProvider,
      // which fires resumeRebindListenerProvider (rebind + liveness probe).
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 300));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      // Give the probe its short timeout window + the live ping reply.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      // The LIVE session must NOT have been driven to softDisconnected/failed
      // by the probe — a good ping reply keeps it connected.
      final stateAfter = container
          .read(sessionsProvider)
          .active!
          .proxy
          .data
          .state;
      expect(
        stateAfter == SshSessionState.connected ||
            stateAfter == SshSessionState.reconnecting,
        isTrue,
        reason:
            'resume probe must not freeze/fail a LIVE session — state was '
            '$stateAfter (#737)',
      );

      // Input after resume must still reach the live shell and echo back —
      // the anti-freeze assertion. Send a newline and watch for fresh bytes.
      final before = out.length;
      entry.proxy.sendInput(Uint8List.fromList('echo wake737\n'.codeUnits));
      var echoed = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (out.length > before) {
          echoed = true;
          break;
        }
      }
      expect(
        echoed,
        isTrue,
        reason:
            'after resume, input produced NO output — the wake-frozen bug '
            '(#737): session accepts input but yields nothing',
      );
    },
  );
}
