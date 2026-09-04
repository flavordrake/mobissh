// SessionHost routing of a FORCED connect on a live session (#1136).
//
// The session menu's "Reconnect (force)" re-issues `connect` for a session that
// is still CONNECTED. `_handleConnect` dedups a connect for an already-hosted
// session (the contract the chooser / attention `addOrActivate` paths rely on),
// so the force intent must ride an explicit `force` bit on the command: forced
// → the controller's `forceReconnect()` (live client torn down, normal
// reconnect path); unforced → state sync only, exactly as before.
//
// Headless via InMemoryGatewayPair + an inert-connect controller.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';

const _sid = 'h:22:u:1';

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
    // Inert — the test seeds `connected` via debugSetConnectedForTest.
  }
}

SshConnectCommand _connect({bool force = false}) => SshConnectCommand(
      sessionId: _sid,
      host: 'h',
      port: 22,
      username: 'u',
      authJson: const {'type': 'password', 'password': 'p'},
      force: force,
    );

Future<void> _pump([int turns = 20]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('SshConnectCommand.force round-trips (and is omitted when false)', () {
    final forced = _connect(force: true).toJson();
    expect(forced['force'], isTrue);
    final decoded = SshTaskCommand.fromJson(forced) as SshConnectCommand;
    expect(decoded.force, isTrue);

    final plain = _connect().toJson();
    expect(plain.containsKey('force'), isFalse);
    expect(
      (SshTaskCommand.fromJson(plain) as SshConnectCommand).force,
      isFalse,
    );
  });

  test(
    'forced connect on a CONNECTED hosted session re-enters the reconnect '
    'path; a plain connect stays a dedup no-op',
    () async {
      var attempts = 0;
      late SshSessionController controller;
      final pair = InMemoryGatewayPair();
      final host = SessionHost(
        gateway: pair.taskSide,
        controllerFactory: () {
          controller = _NoConnectController(
            reconnectDelay: Duration.zero,
            reconnectAttemptOverride: (_) async {
              attempts += 1;
              return true;
            },
          );
          return controller;
        },
        snapshotInterval: const Duration(hours: 1),
      );
      addTearDown(() async {
        await host.dispose();
        await pair.dispose();
      });

      pair.uiSide.send(_connect().toJson());
      await _pump();
      controller.debugSetConnectedForTest(_params);
      await _pump();

      final states = <String>[];
      final sub = pair.uiSide.incoming.listen((json) {
        final ev = SshTaskEvent.fromJson(json);
        if (ev is SshStateEvent) states.add(ev.state);
      });

      // Plain re-issued connect: the dedup contract — no reconnect.
      pair.uiSide.send(_connect().toJson());
      await _pump();
      expect(attempts, 0);
      expect(states, isNot(contains('reconnecting')));

      // Forced: tear down + reconnect.
      pair.uiSide.send(_connect(force: true).toJson());
      await _pump();
      expect(attempts, 1, reason: 'force must run one reconnect attempt');
      expect(states, contains('reconnecting'));
      expect(controller.data.state, SshSessionState.connected);
      await sub.cancel();
    },
  );
}
