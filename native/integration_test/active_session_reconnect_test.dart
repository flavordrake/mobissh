// On-emulator Active Sessions UI: a dropped session is visible + reconnectable
// (#817, #811 Slice 2). Orchestrator-run (tag `integration`).
//
// The owner's pain: "zombie sessions require me to ✕ them, no reconnect option."
// After Slice 2 a non-connected session row must surface a Reconnect affordance
// (not a ✕-only tile), and tapping it must re-enter the connect path from the
// task-held params (no auth re-supply) and reach a LIVE shell again.
//
// This runs the full device path: connect to test-sshd → drop the session
// (proxy.disconnect → `disconnected`) → open the session menu → assert the row
// shows a Reconnect button → tap it → prove the shell streams bytes again.
//
// PASS = the Reconnect button appears on the dropped row AND tapping it revives
// the session to a live shell.

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

Future<bool> _proveShellBytes(
  WidgetTester tester,
  dynamic entry,
) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  var gotBytes = false;
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (out.isNotEmpty) {
      gotBytes = true;
      break;
    }
  }
  await sub.cancel();
  return gotBytes;
}

Future<bool> _connect(WidgetTester tester) async {
  await adhocPasswordConnect(
    tester,
    host: '127.0.0.1',
    port: '2222',
    user: 'testuser',
    pass: 'testpass',
  );
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final accept = find.text('Trust + connect');
    if (accept.evaluate().isNotEmpty) {
      await tester.tap(accept.first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a dropped session shows a Reconnect button that revives a live shell',
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

      expect(await _connect(tester), isTrue, reason: 'initial connect failed');

      final entry = container.read(sessionsProvider).active!;
      final sid = entry.id;

      // Prove the first shell is live before dropping it.
      expect(
        await _proveShellBytes(tester, entry),
        isTrue,
        reason: 'first connect did not stream shell bytes',
      );

      // Drop the session WITHOUT removing the entry: disconnect drives the task
      // controller to `disconnected` while the entry (and its proxy) survives —
      // the zombie-tile condition the owner hit.
      entry.proxy.disconnect();
      var dropped = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        final state = entry.proxy.data.state;
        if (state == SshSessionState.disconnected ||
            state == SshSessionState.failed ||
            state == SshSessionState.softDisconnected) {
          dropped = true;
          break;
        }
      }
      expect(dropped, isTrue, reason: 'session never reached a drop state');
      // The entry must still exist (a drop is not a forget).
      expect(
        container.read(sessionsProvider).entries.any((e) => e.id == sid),
        isTrue,
      );

      // Open the session menu and assert the dropped row surfaces a Reconnect
      // affordance — not a ✕-only tile.
      await tester.tap(find.byKey(const Key('session-bar-open-menu')));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));

      final reconnectBtn = find.byKey(Key('session-menu-reconnect-$sid'));
      expect(
        reconnectBtn,
        findsOneWidget,
        reason: 'a dropped session row must offer Reconnect (#817)',
      );

      // Tap Reconnect → re-enter the connect path from held params.
      await tester.tap(reconnectBtn);
      await tester.pump(const Duration(milliseconds: 300));

      // The session must reach `connected` and stream bytes again.
      var reconnected = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (entry.proxy.data.state == SshSessionState.connected) {
          reconnected = true;
          break;
        }
      }
      expect(
        reconnected,
        isTrue,
        reason: 'Reconnect did not drive the session back to connected',
      );
      expect(
        await _proveShellBytes(tester, entry),
        isTrue,
        reason: 'Reconnect reached connected but no live shell bytes flowed',
      );
    },
  );
}
