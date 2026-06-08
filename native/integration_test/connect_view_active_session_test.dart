// On-emulator: a dropped session is visible + reconnectable from the CONNECT
// VIEW's Active Sessions group (#821 Slice 3, #811, closes #809).
// Orchestrator-run (tag `integration`).
//
// The owner's pain (#809): after a disconnect the session vanished from the
// home/Connect view (recents were suppressed by the lingering entry AND the
// dropped session had no Connect-view surface). Slice 3 brings the in-session
// menu's Reconnect surface (#817) to the Connect view, so a dropped session
// stays reachable from the home screen.
//
// Full device path: connect to test-sshd → drop the session (proxy.disconnect →
// `disconnected`) → open the session menu → "Profiles & settings" (the Connect
// view OVER the live sessions) → assert the dropped session shows an Active
// Sessions row with a Reconnect button → tap it → prove the shell streams bytes
// again.
//
// PASS = the Active Sessions Reconnect button appears on the Connect view AND
// tapping it revives the session to a live shell.

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/sessions.dart';

import 'support/connect_helpers.dart';

Future<bool> _proveShellBytes(WidgetTester tester, dynamic entry) async {
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
    'a dropped session is reconnectable from the Connect view Active Sessions '
    'group (#809)',
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

      expect(
        await _proveShellBytes(tester, entry),
        isTrue,
        reason: 'first connect did not stream shell bytes',
      );

      // Drop the session WITHOUT removing the entry (the zombie-tile condition).
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
      expect(
        container.read(sessionsProvider).entries.any((e) => e.id == sid),
        isTrue,
        reason: 'a drop must not forget the session',
      );

      // Open the session menu, then route to the full Connect view OVER the
      // (dropped) session via "Profiles & settings".
      await tester.tap(find.byKey(const Key('session-bar-open-menu')));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('session-menu-new')));
      await tester.pumpAndSettle(const Duration(milliseconds: 600));

      // The Connect view's Active Sessions group shows the dropped session with
      // a Reconnect affordance — NOT vanished (#809).
      expect(
        find.byKey(const Key('active-sessions-group')),
        findsOneWidget,
        reason: 'the Connect view must show the Active Sessions group',
      );
      final reconnectBtn = find.byKey(Key('active-session-reconnect-$sid'));
      expect(
        reconnectBtn,
        findsOneWidget,
        reason: 'a dropped session must offer Reconnect on the Connect view',
      );

      // Tap Reconnect → re-enter the connect path.
      await tester.tap(reconnectBtn);
      await tester.pump(const Duration(milliseconds: 300));

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
