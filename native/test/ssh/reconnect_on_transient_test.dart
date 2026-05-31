// Reconnect-on-transient-socket-error tests (#517).
//
// `errno 103` (ECONNABORTED) on return-from-app-swap surfaced as a raw
// `SSHSocketError` to the UI. This test exercises the classifier + the
// reconnecting state machine without standing up a real SSH server — the
// controller exposes `handleTransportClosed` as a test seam so we can drive
// the post-`connected` close path directly.

import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';

void main() {
  group('isTransientSocketError classifier', () {
    test('SocketException with errno 103 (ECONNABORTED) is transient', () {
      final err = SSHSocketError(
        const SocketException(
          'Software caused connection abort',
          osError: OSError('Software caused connection abort', 103),
        ),
      );
      expect(SshSessionController.isTransientSocketError(err), isTrue);
    });

    test('SocketException with errno 113 (EHOSTUNREACH) is transient', () {
      final err = SSHSocketError(
        const SocketException(
          'No route to host',
          osError: OSError('No route to host', 113),
        ),
      );
      expect(SshSessionController.isTransientSocketError(err), isTrue);
    });

    test('SocketException with errno 32 (EPIPE) is transient', () {
      final err = SSHSocketError(
        const SocketException(
          'Broken pipe',
          osError: OSError('Broken pipe', 32),
        ),
      );
      expect(SshSessionController.isTransientSocketError(err), isTrue);
    });

    test('any SSHSocketError without a recognised errno is treated as transient',
        () {
      // Generic SSHSocketError post-handshake — kernel/Tailscale teardown
      // with no concrete os error. We still want to retry.
      final err = SSHSocketError('connection closed');
      expect(SshSessionController.isTransientSocketError(err), isTrue);
    });

    test('non-socket errors are not transient', () {
      expect(SshSessionController.isTransientSocketError(Exception('nope')),
          isFalse);
      expect(SshSessionController.isTransientSocketError('string error'),
          isFalse);
    });
  });

  group('SshSessionController reconnect state machine', () {
    test(
        'transient close after connected transitions through reconnecting back '
        'to connected', () async {
      final calls = <String>[];
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        maxReconnectAttempts: 3,
        // Reconnect attempt invokes this — pretend connect succeeded.
        reconnectAttemptOverride: (params) async {
          calls.add('reconnect:${params.host}');
          // Simulate successful reconnect by transitioning back via the
          // testable transition seam.
          return true;
        },
      );

      // Seed connected state + last params.
      controller.debugSetConnectedForTest(const SshConnectParams(
        host: 'example',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));

      expect(controller.data.state, SshSessionState.connected);

      // Simulate transient transport close.
      controller.handleTransportClosed(SSHSocketError(
        const SocketException(
          'Software caused connection abort',
          osError: OSError('Software caused connection abort', 103),
        ),
      ));

      // Drain microtasks for the scheduled reconnect.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(calls, contains('reconnect:example'));
      expect(controller.data.state, SshSessionState.connected);

      await controller.dispose();
    });

    test('repeated transient failures eventually surface as failed', () async {
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        maxReconnectAttempts: 2,
        reconnectAttemptOverride: (_) async => false, // always fail
      );

      controller.debugSetConnectedForTest(const SshConnectParams(
        host: 'example',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));

      controller.handleTransportClosed(SSHSocketError(
        const SocketException(
          'broken',
          osError: OSError('broken', 32),
        ),
      ));

      // Drain microtasks for multiple reconnect attempts.
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.data.state, SshSessionState.failed);
      expect(controller.data.error, isNotNull);
      expect(controller.data.error, contains('reconnect'));

      await controller.dispose();
    });

    test('user-initiated disconnect does NOT trigger reconnect', () async {
      var reconnectCalled = false;
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        maxReconnectAttempts: 5,
        reconnectAttemptOverride: (_) async {
          reconnectCalled = true;
          return true;
        },
      );

      controller.debugSetConnectedForTest(const SshConnectParams(
        host: 'example',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));

      await controller.disconnect();

      // Even if a stale done-future resolves with a socket error post-disconnect,
      // the controller must not attempt to reconnect.
      controller.handleTransportClosed(SSHSocketError(
        const SocketException(
          'closed',
          osError: OSError('closed', 103),
        ),
      ));

      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(reconnectCalled, isFalse);
      expect(controller.data.state, SshSessionState.disconnected);

      await controller.dispose();
    });

    test(
        'clean close while connected soft-disconnects then auto-reconnects '
        '(#551 behavior change)', () async {
      // Pre-#551 this asserted "clean close → disconnected, no reconnect".
      // #551 redefines a clean server-initiated close while `connected` as a
      // soft disconnect that auto-reconnects (creds are still valid). The
      // straight-to-disconnected path now only applies when we were NOT
      // connected — see the dedicated test in ssh_session_test.dart.
      var reconnectCalled = false;
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        reconnectAttemptOverride: (_) async {
          reconnectCalled = true;
          return true;
        },
      );

      controller.debugSetConnectedForTest(const SshConnectParams(
        host: 'example',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));

      // Clean close — no error.
      controller.handleTransportClosed(null);

      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
        if (controller.data.state == SshSessionState.connected) break;
      }

      expect(reconnectCalled, isTrue,
          reason: 'clean close while connected must auto-reconnect (#551)');
      expect(controller.data.state, SshSessionState.connected);

      await controller.dispose();
    });

    test('keepAliveInterval defaults to 15 seconds', () {
      final controller = SshSessionController();
      expect(controller.keepAliveInterval, const Duration(seconds: 15));
      controller.dispose();
    });

    test('keepAliveInterval is honoured when overridden', () {
      final controller = SshSessionController(
        keepAliveInterval: const Duration(seconds: 30),
      );
      expect(controller.keepAliveInterval, const Duration(seconds: 30));
      controller.dispose();
    });
  });
}
