// State-machine hardening tests (#813 Slice 1).
//
// Two concerns:
//  1. `_userDisconnected` folded into state — a user Disconnect lands in
//     `disconnected` and suppresses auto-reconnect; decision logic reads STATE,
//     never a flag combo. We assert the externally-observable behaviour: after a
//     user disconnect, no involuntary close path (stale done-future,
//     probeLiveness, softDisconnectForResume) re-arms reconnect.
//  2. A `failed` (and involuntary-`disconnected`) session re-arms to
//     `reconnecting` on a stale resume; a user-`disconnected` session does NOT.

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

void main() {
  group('user Disconnect folds into `disconnected` + suppresses reconnect', () {
    test(
      'user disconnect → disconnected; a later stale transient close does NOT '
      'reconnect (state, not flag, gates it)',
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

        // A stale done-future resolves with a transient error AFTER the user
        // disconnected. The `disconnected` state must suppress reconnect.
        controller.handleTransportClosed(
          SSHSocketError(
            const SocketException('closed', osError: OSError('closed', 103)),
          ),
        );
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(controller.data.state, SshSessionState.disconnected);
        expect(reconnectCalled, isFalse);
        await controller.dispose();
      },
    );

    test('probeLiveness is a no-op after a user disconnect (disconnected state)',
        () async {
      var probed = false;
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        livenessProbeOverride: () async {
          probed = true;
        },
      );
      controller.debugSetConnectedForTest(_params);
      await controller.disconnect();

      final alive = await controller.probeLiveness(
        timeout: const Duration(milliseconds: 10),
      );

      expect(probed, isFalse, reason: 'disconnected → nothing to probe');
      expect(alive, isFalse);
      expect(controller.data.state, SshSessionState.disconnected);
      await controller.dispose();
    });

    test(
      'softDisconnectForResume is a no-op after a user disconnect',
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

        controller.softDisconnectForResume();
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(controller.data.state, SshSessionState.disconnected);
        expect(reconnectCalled, isFalse);
        await controller.dispose();
      },
    );
  });

  group('failed → reconnecting resume re-arm (#813)', () {
    test(
      'connect → drop → exhaust → failed; stale resume re-arms to reconnecting',
      () async {
        var attempts = 0;
        final controller = SshSessionController(
          reconnectDelay: Duration.zero,
          maxReconnectAttempts: 1,
          reconnectAttemptOverride: (_) async {
            attempts += 1;
            // First exhaust to `failed`; after re-arm, let it succeed so the
            // session settles deterministically.
            return attempts > 1;
          },
        );
        controller.debugSetConnectedForTest(_params);

        // Transient drop → reconnect attempt fails → exhausted → failed.
        controller.handleTransportClosed(
          SSHSocketError(
            const SocketException('broken', osError: OSError('broken', 32)),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
          if (controller.data.state == SshSessionState.failed) break;
        }
        expect(controller.data.state, SshSessionState.failed);

        final states = <SshSessionState>[];
        final sub = controller.stream.listen((d) => states.add(d.state));

        // Simulate app-resume past the stale threshold: the failed session must
        // re-arm reconnect from its held params.
        await controller.resumeReconnectIfStale(
          staleThreshold: Duration.zero,
        );
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
          if (controller.data.state == SshSessionState.connected) break;
        }

        expect(
          states,
          contains(SshSessionState.reconnecting),
          reason: 'a stale failed session must re-arm to reconnecting on resume',
        );

        await sub.cancel();
        await controller.dispose();
      },
    );

    test('a user-disconnected session does NOT re-arm on resume', () async {
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

      await controller.resumeReconnectIfStale(staleThreshold: Duration.zero);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(
        controller.data.state,
        SshSessionState.disconnected,
        reason: 'a user disconnect must never be auto-re-armed',
      );
      expect(reconnectCalled, isFalse);
      await controller.dispose();
    });

    test('resumeReconnectIfStale is a no-op on a connected session', () async {
      var reconnectCalled = false;
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        reconnectAttemptOverride: (_) async {
          reconnectCalled = true;
          return true;
        },
      );
      controller.debugSetConnectedForTest(_params);

      await controller.resumeReconnectIfStale(staleThreshold: Duration.zero);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.data.state, SshSessionState.connected);
      expect(reconnectCalled, isFalse);
      await controller.dispose();
    });
  });
}
