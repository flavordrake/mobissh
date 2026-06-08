// User-initiated FORCE reconnect tests (#817, Active Sessions UI Reconnect).
//
// `reconnectNow()` backs the Reconnect button on a dropped session row. Unlike
// the app-resume re-arm (`resumeReconnectIfStale`), it:
//  - fires immediately (no staleness threshold),
//  - OVERRIDES a prior user disconnect (tapping Reconnect is an explicit revive
//    intent — distinct from the resume re-arm, which must never auto-revive a
//    user ✕),
//  - cancels any pending backoff and retries now from a `softDisconnected` /
//    `reconnecting` session,
//  - is a no-op for a healthy/connecting session and when there are no held
//    params.
//
// We assert externally-observable transitions (states emitted) and whether the
// reconnect attempt ran — never a private flag (rules/state-management.md).

import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';

const _params = SshConnectParams(
  host: 'example',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

Future<void> _settle(SshSessionController c, SshSessionState target) async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
    if (c.data.state == target) return;
  }
}

void main() {
  test('reconnectNow on a `failed` session re-arms to reconnecting → connected',
      () async {
    var attempts = 0;
    final controller = SshSessionController(
      reconnectDelay: Duration.zero,
      maxReconnectAttempts: 1,
      reconnectAttemptOverride: (_) async {
        attempts += 1;
        return attempts > 1; // exhaust to failed, then succeed on the re-arm
      },
    );
    controller.debugSetConnectedForTest(_params);

    controller.handleTransportClosed(
      SSHSocketError(
        const SocketException('broken', osError: OSError('broken', 32)),
      ),
    );
    await _settle(controller, SshSessionState.failed);
    expect(controller.data.state, SshSessionState.failed);

    final states = <SshSessionState>[];
    final sub = controller.stream.listen((d) => states.add(d.state));

    controller.reconnectNow();
    await _settle(controller, SshSessionState.connected);

    expect(states, contains(SshSessionState.reconnecting));
    expect(controller.data.state, SshSessionState.connected);
    await sub.cancel();
    await controller.dispose();
  });

  test(
    'reconnectNow OVERRIDES a user disconnect (explicit revive intent)',
    () async {
      var reconnectCalled = false;
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        reconnectAttemptOverride: (_) async {
          reconnectCalled = true;
          return true;
        },
      );
      controller.debugSetConnectedForTest(_params);
      await controller.disconnect();
      expect(controller.data.state, SshSessionState.disconnected);

      // The resume re-arm must NOT revive this (regression guard for #813)...
      await controller.resumeReconnectIfStale(staleThreshold: Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(reconnectCalled, isFalse);
      expect(controller.data.state, SshSessionState.disconnected);

      // ...but an explicit Reconnect tap MUST.
      controller.reconnectNow();
      await _settle(controller, SshSessionState.connected);
      expect(reconnectCalled, isTrue);
      expect(controller.data.state, SshSessionState.connected);
      await controller.dispose();
    },
  );

  test(
    'reconnectNow on a `reconnecting` session re-arms with a fresh budget',
    () async {
      var attempts = 0;
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        maxReconnectAttempts: 5,
        reconnectAttemptOverride: (_) async {
          attempts += 1;
          return true;
        },
      );
      controller.debugSetConnectedForTest(_params);

      // Clean server close → softDisconnected → schedules a reconnect.
      controller.handleTransportClosed(null);
      // Force-now from a mid-reconnect state: re-enters the reconnect path and
      // settles connected (the override succeeds). The force is a no-op-safe
      // re-arm even while a schedule is already pending.
      controller.reconnectNow();
      await _settle(controller, SshSessionState.connected);
      expect(controller.data.state, SshSessionState.connected);
      expect(attempts, greaterThanOrEqualTo(1));
      await controller.dispose();
    },
  );

  test('reconnectNow is a no-op on a connected session', () async {
    var reconnectCalled = false;
    final controller = SshSessionController(
      reconnectDelay: Duration.zero,
      reconnectAttemptOverride: (_) async {
        reconnectCalled = true;
        return true;
      },
    );
    controller.debugSetConnectedForTest(_params);

    controller.reconnectNow();
    await Future<void>.delayed(Duration.zero);

    expect(controller.data.state, SshSessionState.connected);
    expect(reconnectCalled, isFalse);
    await controller.dispose();
  });

  test('reconnectNow is a no-op when there are no held params (never connected)',
      () async {
    final controller = SshSessionController(reconnectDelay: Duration.zero);
    // idle, no _lastParams.
    controller.reconnectNow();
    await Future<void>.delayed(Duration.zero);
    expect(controller.data.state, SshSessionState.idle);
    await controller.dispose();
  });
}
