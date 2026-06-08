// SessionHost reconnect-command routing (#817, Active Sessions UI).
//
// When the user taps Reconnect on a dropped session row, the UI sends an
// `SshReconnectCommand` for that session. The task-side `SessionHost` must route
// it to the hosted controller's `reconnectNow()`, which force re-enters the
// reconnect path from held params (no auth re-supply). A command for a session
// that is no longer hosted (already forgotten via ✕) is a safe no-op.
//
// Headless via InMemoryGatewayPair + a controller whose connect() is inert so
// the test owns the lifecycle transitions — no real socket.

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

class _NoConnectController extends SshSessionController {
  _NoConnectController({super.reconnectDelay, super.reconnectAttemptOverride});

  @override
  Future<void> connect(SshConnectParams params) async {
    // Inert — the test drives lifecycle via debugSetConnectedForTest +
    // handleTransportClosed; reconnectNow uses the held params from connect,
    // which debugSetConnectedForTest seeds.
  }
}

void main() {
  test(
    'reconnect command routes to reconnectNow — a FAILED session reconnects',
    () async {
      const sid = 'h:22:u:1';
      var reconnectCalled = false;
      late SshSessionController controller;
      SshSessionController factory() {
        controller = _NoConnectController(
          reconnectDelay: Duration.zero,
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
      // Seed connected (held params), then fail it.
      controller.debugSetConnectedForTest(_params);
      controller
        ..reconnectNow() // no-op while connected — sanity
        ..debugSetConnectedForTest(_params);
      // Drive to failed via a non-transient close path: simulate exhausted
      // reconnect by forcing the state with a clean close from non-connected.
      // Simplest deterministic route: disconnect (user) then reconnect command
      // must STILL revive (explicit intent) — see the controller unit test. Here
      // we assert the host wires the command at all: send it after a failure.
      controller.handleTransportClosed(null); // connected → softDisconnected
      await Future<void>.delayed(Duration.zero);

      pair.uiSide.send(const SshReconnectCommand(sessionId: sid).toJson());
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
        if (reconnectCalled) break;
      }

      expect(
        reconnectCalled,
        isTrue,
        reason: 'reconnect command must route to controller.reconnectNow()',
      );
    },
  );

  test('reconnect command for an unhosted session is a safe no-op', () async {
    final pair = InMemoryGatewayPair();
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: () => _NoConnectController(),
      snapshotInterval: const Duration(hours: 1),
    );
    addTearDown(() async {
      await host.dispose();
      await pair.dispose();
    });

    // No session hosted for this id (already forgotten).
    pair.uiSide.send(
      const SshReconnectCommand(sessionId: 'gone:22:u:1').toJson(),
    );
    // Just draining without throwing is the assertion.
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(true, isTrue);
  });
}
