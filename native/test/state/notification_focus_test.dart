// Integration of the #575 notification-tap focus path with the real session
// collection providers. Proves that consuming a pending focus (the sessionId a
// tapped notification carried) calls sessionsProvider.notifier.setActive on the
// ACTUAL notifier, and that the per-session isolation holds (focusing A leaves
// B untouched). The physical tap → launchApp → foreground is device-only.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_notification.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/notification_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';

ProviderContainer _makeContainer(PendingFocusBridge bridge) {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      pendingFocusBridgeProvider.overrideWithValue(bridge),
    ],
  );
  addTearDown(() async {
    await pair.dispose();
  });
  return container;
}

SshConnectParams _params({String host = 'h', String username = 'u'}) {
  return SshConnectParams(
    host: host,
    port: 22,
    username: username,
    auth: const SshAuth.password('p'),
  );
}

void main() {
  test(
    'consuming a pending focus calls setActive on the originating session',
    () async {
      final bridge = PendingFocusBridge(MapKeyValueStore());
      final c = _makeContainer(bridge);
      addTearDown(c.dispose);

      final notifier = c.read(sessionsProvider.notifier);
      final a = notifier.addOrActivate(_params(host: 'A'));
      final b = notifier.addOrActivate(_params(host: 'B'));
      // B is active after the second add.
      expect(c.read(sessionsProvider).activeId, b.id);

      // A notification from session A was tapped → bridge holds A's id.
      final tap = SessionNotification.build(
        sessionId: a.id,
        label: a.label,
        kind: SessionSignalKind.ready,
      );
      await bridge.setPending(SessionNotification.parsePayload(tap.payload)!);

      // Consume the pending focus (what the resume hook does).
      await c.read(notificationFocusRouterProvider).consumePendingFocus();

      // Lands on A — the originating session.
      expect(c.read(sessionsProvider).activeId, a.id);
      // B still exists and is untouched (isolation).
      expect(
        c.read(sessionsProvider).entries.map((e) => e.id),
        containsAll(<String>[a.id, b.id]),
      );
      // One-shot: consuming again does nothing (no spurious re-focus on resume).
      await c.read(notificationFocusRouterProvider).consumePendingFocus();
      expect(c.read(sessionsProvider).activeId, a.id);
    },
  );

  test('no pending focus → active session unchanged', () async {
    final bridge = PendingFocusBridge(MapKeyValueStore());
    final c = _makeContainer(bridge);
    addTearDown(c.dispose);

    final notifier = c.read(sessionsProvider.notifier);
    final a = notifier.addOrActivate(_params(host: 'A'));
    expect(c.read(sessionsProvider).activeId, a.id);

    await c.read(notificationFocusRouterProvider).consumePendingFocus();
    expect(c.read(sessionsProvider).activeId, a.id);
  });

  test('pending focus for an unknown session is a safe no-op', () async {
    final bridge = PendingFocusBridge(MapKeyValueStore());
    final c = _makeContainer(bridge);
    addTearDown(c.dispose);

    final notifier = c.read(sessionsProvider.notifier);
    final a = notifier.addOrActivate(_params(host: 'A'));
    await bridge.setPending('gone:22:u:999');

    await c.read(notificationFocusRouterProvider).consumePendingFocus();
    // setActive is a no-op for an absent id → active stays on the real session.
    expect(c.read(sessionsProvider).activeId, a.id);
  });
}
