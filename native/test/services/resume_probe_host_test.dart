// SessionHost resume-probe routing (#737).
//
// On `AppLifecycleState.resumed` the UI sends an `SshResumeProbeCommand` for
// each live session. The task-side `SessionHost` must route it to the hosted
// controller's `probeLiveness()` so a zombie-`connected` (dead half-open socket
// surviving Doze) is actively pinged instead of trusted. A live session's probe
// succeeds (stays connected); a dead session's probe times out → the controller
// transitions to softDisconnected and the existing reconnect path runs.
//
// Headless via InMemoryGatewayPair + a controller whose probe seam is forced
// live/dead — no real socket.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';

const _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

/// A controller whose real `connect()` is a no-op so the test owns the
/// `connected` transition (via [debugSetConnectedForTest]) without any socket /
/// auth race. The host only needs the controller hosted + its state stream
/// wired; the resume probe routes to [probeLiveness], which the injected
/// liveness seam drives deterministically.
class _NoConnectController extends SshSessionController {
  _NoConnectController({
    super.reconnectDelay,
    super.maxReconnectAttempts,
    super.livenessProbeOverride,
    super.reconnectAttemptOverride,
  });

  @override
  Future<void> connect(SshConnectParams params) async {
    // Intentionally inert — no socket, no auth. Tests drive `connected`.
  }
}

void main() {
  test(
    'resumeProbe routes to probeLiveness — a DEAD session reconnects (#737)',
    () async {
      const sid = 'h:22:u:1';
      var reconnectCalled = false;
      late SshSessionController controller;
      SshSessionController factory() {
        controller = _NoConnectController(
          reconnectDelay: Duration.zero,
          maxReconnectAttempts: 3,
          // Dead half-open socket: the probe never replies.
          livenessProbeOverride: () => Completer<void>().future,
          reconnectAttemptOverride: (_) async {
            reconnectCalled = true;
            return true;
          },
        );
        return controller;
      }

      final pair = InMemoryGatewayPair();
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: factory,
        // Short probe timeout so the test runs fast.
        resumeProbeTimeout: const Duration(milliseconds: 10),
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(() async {
        await host.dispose();
        await pair.dispose();
      });

      // Host the session (connect over the gateway → host._handleConnect),
      // then drive it to connected. The silent socket means real auth never
      // completes, so the test owns the `connected` transition.
      pair.uiSide.send(
        const SshConnectCommand(
          sessionId: sid,
          host: 'h',
          port: 22,
          username: 'u',
          authJson: {'type': 'password', 'password': 'p'},
        ).toJson(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      controller.debugSetConnectedForTest(_params);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(controller.data.state, SshSessionState.connected);

      // Simulate the resume probe arriving from the UI side.
      pair.uiSide.send(const SshResumeProbeCommand(sessionId: sid).toJson());

      // Drain: probe times out (10ms) → softDisconnected → reconnect. Use real
      // delays so the 10ms timeout timer actually fires (microtask drains alone
      // don't advance wall time).
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (reconnectCalled) break;
      }

      expect(
        reconnectCalled,
        isTrue,
        reason:
            'resumeProbe must probe the dead session and trigger reconnect '
            '(#737 wake-frozen)',
      );
    },
  );

  test(
    'resumeProbe leaves a LIVE session connected — no reconnect (#737)',
    () async {
      const sid = 'h:22:u:1';
      var reconnectCalled = false;
      late SshSessionController controller;
      SshSessionController factory() {
        controller = _NoConnectController(
          reconnectDelay: Duration.zero,
          livenessProbeOverride: () async {}, // replies immediately
          reconnectAttemptOverride: (_) async {
            reconnectCalled = true;
            return true;
          },
        );
        return controller;
      }

      final pair = InMemoryGatewayPair();
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: factory,
        resumeProbeTimeout: const Duration(milliseconds: 50),
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(() async {
        await host.dispose();
        await pair.dispose();
      });

      pair.uiSide.send(
        const SshConnectCommand(
          sessionId: sid,
          host: 'h',
          port: 22,
          username: 'u',
          authJson: {'type': 'password', 'password': 'p'},
        ).toJson(),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      controller.debugSetConnectedForTest(_params);
      await Future<void>.delayed(Duration.zero);

      pair.uiSide.send(const SshResumeProbeCommand(sessionId: sid).toJson());
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.data.state, SshSessionState.connected);
      expect(
        reconnectCalled,
        isFalse,
        reason: 'a live session must not reconnect on resume probe',
      );
    },
  );
}
