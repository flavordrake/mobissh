// On-emulator disconnect-telemetry test (#838).
//
// Proves the disconnect-case instrumentation against a LIVE sshd end-to-end:
// after a real connect + shell, a user Disconnect must write ONE structured
// `disconnect:` line into the DURABLE lifecycle ring carrying the cause label,
// the end-time→detection latency, and a single edge# ("cut once"). This is the
// on-device gate for the telemetry the eventual #766 mid-session-liveness fix
// will be built + validated from.
//
// SEAM / coverage boundary (per #589):
//   - The CAUSE classification, LATENCY computation, single-edge "cut once"
//     guard, and the liveness HEARTBEAT are covered DETERMINISTICALLY in
//     test/services/disconnect_telemetry_test.dart and
//     test/services/liveness_heartbeat_test.dart (injected clock + inert
//     controller — every cause, exact latency, growing silent-drop age).
//   - THIS emulator test proves the END-TO-END path against a real sshd: a real
//     connect → shell → user Disconnect lands a `disconnect:` line in the ring
//     the feedback bundle reads. Inducing transport socket-error / Doze
//     half-open drops needs OS-level Doze the emulator can't reproduce, so the
//     headless seams stand in for those causes; this guards that the real
//     wiring emits the line at all.
//
// SKIPPED (skip: true), matching resume_liveness_test.dart: a LIVE ghostty
// terminal view + the foreground-task isolate keep the integration binding from
// ever idling, so pump never settles. Orchestrator runs it on a booted emulator
// as the device gate; CI/fast-gate excludes integration_test.

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/diagnostics/connect_trace.dart';
import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a real connect + user Disconnect writes a single disconnect line with '
    'cause + latency to the durable lifecycle ring (#838)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();
      clearConnectLog();
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
      expect(connected, isTrue, reason: 'initial connect did not reach a shell');

      // Prove the first shell streams bytes (so tLastActivity is a real byte).
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull);
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
      expect(gotBytes, isTrue, reason: 'no pre-disconnect shell bytes');

      // User Disconnect: open the session menu, tap Disconnect (#607).
      await tester.tap(find.byKey(const Key('session-bar-open-menu')));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('terminal-disconnect-button')));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(const Key('new-connection')).evaluate().isNotEmpty) {
          break;
        }
      }

      // The disconnect must have landed a structured line in the durable ring
      // (forwarded task→UI via SshLifecycleEvent). Exactly one drop edge.
      final drops = lifecycleLogSnapshot()
          .where((l) => l.contains('disconnect:'))
          .toList();
      expect(
        drops.length,
        1,
        reason:
            'exactly ONE disconnect line per user Disconnect (cut once). '
            'Ring: ${lifecycleLogSnapshot().join('\n')}',
      );
      final line = drops.single;
      expect(line, contains('cause=user-disconnect'));
      expect(line, contains('intent=user'));
      expect(line, contains('latencyMs='));
      expect(line, contains('edge=1'));
    },
    skip: true,
  );
}
