// Resume liveness-probe tests (#737).
//
// Wake-from-sleep freeze: during Doze the SSH TCP socket dies half-open and the
// 15s keepalive timer is frozen, so on resume the session is still `connected`
// with a DEAD socket. The old resume handler only `rebind()`s (re-subscribe +
// re-emit cached snapshot) — it never verifies liveness, so input flows into a
// dead pipe, no output returns, and the #517/#590 auto-reconnect never fires.
//
// The fix: an ACTIVE liveness probe on resume. `probeLiveness()` sends an
// app-level SSH keepalive ping with a SHORT timeout. On timeout/error the socket
// is declared dead immediately (not "never") → `connected` transitions to
// `softDisconnected` → the existing reconnect path re-opens the shell. On a live
// session the probe succeeds and the session stays `connected` (no spurious
// reconnect).
//
// Deterministic: the probe is injected (no real socket / network / wall clock).

import 'dart:async';

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
  group('SshSessionController.probeLiveness (#737)', () {
    test(
      'a connected session whose probe TIMES OUT → softDisconnected → reconnect',
      () async {
        final reconnects = <String>[];
        final controller = SshSessionController(
          reconnectDelay: Duration.zero,
          maxReconnectAttempts: 3,
          // The probe never completes (dead half-open socket) — the short
          // timeout must declare it dead.
          livenessProbeOverride: () => Completer<void>().future,
          reconnectAttemptOverride: (p) async {
            reconnects.add('reconnect:${p.host}');
            return true;
          },
        );
        controller.debugSetConnectedForTest(_params);
        expect(controller.data.state, SshSessionState.connected);

        // Probe with a tiny timeout. The hung probe must time out and drive the
        // session through softDisconnected into the reconnect path.
        final states = <SshSessionState>[];
        final sub = controller.stream.listen((d) => states.add(d.state));

        await controller.probeLiveness(
          timeout: const Duration(milliseconds: 10),
        );

        // Drain the reconnect microtasks.
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
          if (controller.data.state == SshSessionState.connected) break;
        }

        expect(
          states,
          contains(SshSessionState.softDisconnected),
          reason: 'a dead probe must transition connected → softDisconnected',
        );
        expect(
          reconnects,
          contains('reconnect:example'),
          reason: 'softDisconnected must trigger the existing reconnect path',
        );

        await sub.cancel();
        await controller.dispose();
      },
    );

    test(
      'a LIVE session whose probe SUCCEEDS stays connected — no reconnect',
      () async {
        var reconnectCalled = false;
        final controller = SshSessionController(
          reconnectDelay: Duration.zero,
          livenessProbeOverride: () async {}, // ping replies immediately
          reconnectAttemptOverride: (_) async {
            reconnectCalled = true;
            return true;
          },
        );
        controller.debugSetConnectedForTest(_params);

        await controller.probeLiveness(
          timeout: const Duration(milliseconds: 50),
        );
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          controller.data.state,
          SshSessionState.connected,
          reason: 'a live probe must leave the session connected',
        );
        expect(
          reconnectCalled,
          isFalse,
          reason: 'a live session must NOT spuriously reconnect on resume',
        );

        await controller.dispose();
      },
    );

    test(
      'a probe that ERRORS (broken pipe) → softDisconnected → reconnect',
      () async {
        final reconnects = <String>[];
        final controller = SshSessionController(
          reconnectDelay: Duration.zero,
          maxReconnectAttempts: 3,
          livenessProbeOverride: () async {
            throw StateError('ping failed: transport closed');
          },
          reconnectAttemptOverride: (p) async {
            reconnects.add('reconnect:${p.host}');
            return true;
          },
        );
        controller.debugSetConnectedForTest(_params);

        await controller.probeLiveness(
          timeout: const Duration(milliseconds: 50),
        );
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
          if (controller.data.state == SshSessionState.connected) break;
        }

        expect(
          reconnects,
          contains('reconnect:example'),
          reason: 'a ping that throws must also drive the reconnect path',
        );

        await controller.dispose();
      },
    );

    test(
      'probeLiveness is a no-op when NOT connected (idle/reconnecting)',
      () async {
        var probed = false;
        final controller = SshSessionController(
          reconnectDelay: Duration.zero,
          livenessProbeOverride: () async {
            probed = true;
          },
        );
        // Never connected — stays idle.
        expect(controller.data.state, SshSessionState.idle);

        await controller.probeLiveness(
          timeout: const Duration(milliseconds: 10),
        );

        expect(
          probed,
          isFalse,
          reason: 'no live socket to probe when not connected — must no-op',
        );
        expect(controller.data.state, SshSessionState.idle);

        await controller.dispose();
      },
    );

    test('probeLiveness returns TRUE when the ping answers (#759)', () async {
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        livenessProbeOverride: () async {}, // answers immediately
      );
      controller.debugSetConnectedForTest(_params);

      final alive = await controller.probeLiveness(
        timeout: const Duration(milliseconds: 50),
      );

      expect(
        alive,
        isTrue,
        reason:
            'a transport ping that answers reports alive so the host '
            'can decide whether to escalate to the nudge check',
      );
      expect(controller.data.state, SshSessionState.connected);

      await controller.dispose();
    });

    test('probeLiveness returns FALSE when the ping fails (#759)', () async {
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        maxReconnectAttempts: 3,
        livenessProbeOverride: () => Completer<void>().future,
        reconnectAttemptOverride: (_) async => true,
      );
      controller.debugSetConnectedForTest(_params);

      final alive = await controller.probeLiveness(
        timeout: const Duration(milliseconds: 10),
      );

      expect(
        alive,
        isFalse,
        reason: 'a failed ping reports dead AND drives the reconnect path',
      );

      await controller.dispose();
    });

    test(
      'softDisconnectForResume drives connected → softDisconnected → reconnect '
      '(#759)',
      () async {
        final reconnects = <String>[];
        final controller = SshSessionController(
          reconnectDelay: Duration.zero,
          maxReconnectAttempts: 3,
          reconnectAttemptOverride: (p) async {
            reconnects.add('reconnect:${p.host}');
            return true;
          },
        );
        controller.debugSetConnectedForTest(_params);

        final states = <SshSessionState>[];
        final sub = controller.stream.listen((d) => states.add(d.state));

        controller.softDisconnectForResume();
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
          if (controller.data.state == SshSessionState.connected) break;
        }

        expect(states, contains(SshSessionState.softDisconnected));
        expect(reconnects, contains('reconnect:example'));

        await sub.cancel();
        await controller.dispose();
      },
    );

    test('softDisconnectForResume is a no-op when NOT connected', () async {
      var reconnectCalled = false;
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        reconnectAttemptOverride: (_) async {
          reconnectCalled = true;
          return true;
        },
      );
      // Never connected.
      expect(controller.data.state, SshSessionState.idle);

      controller.softDisconnectForResume();
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.data.state, SshSessionState.idle);
      expect(reconnectCalled, isFalse);

      await controller.dispose();
    });

    test('a user-disconnected session is not probed/reconnected', () async {
      var reconnectCalled = false;
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        livenessProbeOverride: () => Completer<void>().future,
        reconnectAttemptOverride: (_) async {
          reconnectCalled = true;
          return true;
        },
      );
      controller.debugSetConnectedForTest(_params);
      await controller.disconnect();

      await controller.probeLiveness(timeout: const Duration(milliseconds: 10));
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.data.state, SshSessionState.disconnected);
      expect(reconnectCalled, isFalse);

      await controller.dispose();
    });
  });
}
