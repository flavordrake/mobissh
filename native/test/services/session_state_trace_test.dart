// SessionHost state-transition telemetry (#836).
//
// Problem 1 of #836: a "disconnected with no indication" report shipped a
// connect-log that was almost entirely the per-frame `[ui.fit659] no
// TerminalViewState yet (offstage?)` spam — it flooded the 200-event connect
// ring and BURIED the disconnect. Worse, the only place a state transition was
// recorded was the TERMINAL bytes (`_emitConnectStatus`), NOT the ctrace ring,
// so a silent mid-session drop left NO trace event to find.
//
// The fix routes every state transition through `clifecycle`, which lands in
// the dedicated lifecycle ring (capacity 80, NEVER evicted by connect-ring
// churn) AND forwards UI-side. These tests assert a `connected → softDisconnected`
// drop writes a transition line that SURVIVES a connect-ring flood — exactly the
// flood the offstage-fit spam used to cause.
//
// Headless via InMemoryGatewayPair + a no-connect controller driven through the
// `connected` → `softDisconnected` transition with no real socket.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/connect_trace.dart';
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

/// A controller whose real `connect()` is inert so the test owns the
/// `connected` transition and the drop (via `handleTransportClosed`). The
/// reconnect attempt is forced to fail-fast so the session settles instead of
/// looping while the test inspects the trace.
class _NoConnectController extends SshSessionController {
  _NoConnectController({super.reconnectDelay, super.reconnectAttemptOverride});

  @override
  Future<void> connect(SshConnectParams params) async {
    // Inert — no socket, no auth. The test drives the state machine directly.
  }
}

void main() {
  setUp(clearConnectLog);
  tearDown(() {
    lifecycleForwarder = null;
    clearConnectLog();
  });

  test(
    'a connected → softDisconnected drop writes a transition line to the '
    'lifecycle ring that SURVIVES connect-ring churn (#836)',
    () async {
      const sid = 'h:22:u:1';
      late SshSessionController controller;
      SshSessionController factory() {
        controller = _NoConnectController(
          reconnectDelay: Duration.zero,
          // Fail-fast so the drop settles (no reconnect loop spamming state).
          reconnectAttemptOverride: (_) async => false,
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

      // Host + connect the session, then drive it to connected.
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

      // Drop the transport — the device's mid-session disconnect. This drives
      // connected → softDisconnected through the controller's state stream,
      // which the host's listener observes and traces. (The session then
      // continues toward reconnecting/failed; we only care that the DROP edge
      // was recorded.)
      controller.handleTransportClosed(null);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The drop must have been recorded in the DURABLE lifecycle ring.
      final lifecycle = lifecycleLogSnapshot().join('\n');
      expect(
        lifecycle,
        contains('state: connected → softDisconnected'),
        reason:
            'a mid-session drop must write a state-transition line to the '
            'lifecycle ring so it is observable in the connect-log bundle '
            '(#836). Lifecycle ring: $lifecycle',
      );

      // Now flood the connect ring past its cap — the exact thing the per-frame
      // fit659 offstage spam used to do. The dedicated lifecycle ring must STILL
      // retain the drop event.
      for (var i = 0; i < connectLogCapacity + 50; i++) {
        ctrace('ui.fit659', 'no TerminalViewState yet (offstage?) $i');
      }

      expect(
        lifecycleLogSnapshot().join('\n'),
        contains('state: connected → softDisconnected'),
        reason:
            'the drop transition must outlive a connect-ring flood — the whole '
            'point of #836 telemetry hygiene. The fit659 spam must never be '
            'able to bury a disconnect again.',
      );
    },
  );
}
