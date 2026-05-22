// Integration test — connects to the test-sshd container on the `mobissh`
// Docker network and walks through the full Phase 1 lifecycle: connecting ->
// awaitingHostKey -> authenticating -> connected -> disconnected.
//
// Skipped from default unit-only runs via the `@Tags(['integration'])`
// annotation. Run with:
//   scripts/flutter-cmd.sh --in native test --tags integration test/ssh_connect_integration_test.dart
//
// Prerequisites:
//   docker compose -f docker-compose.test.yml up -d test-sshd
// See `native/README.md` for the full setup.

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';

void main() {
  group('SshSessionController against test-sshd', () {
    final host = Platform.environment['SSHD_HOST'] ?? 'test-sshd';
    final port =
        int.tryParse(Platform.environment['SSHD_PORT'] ?? '22') ?? 22;
    const user = 'testuser';
    const pass = 'testpass';

    test('connects, accepts host key, authenticates with password, disconnects',
        () async {
      final controller = SshSessionController(
        handshakeTimeout: const Duration(seconds: 10),
      );
      final transitions = <SshSessionState>[];
      final sub = controller.stream.listen((d) => transitions.add(d.state));

      // Auto-accept the host-key prompt as soon as it appears.
      final hostKeyAccepted = Completer<void>();
      final autoAccept = controller.stream
          .firstWhere((d) => d.state == SshSessionState.awaitingHostKey)
          .then((_) {
        controller.acceptHostKey();
        hostKeyAccepted.complete();
      });

      // Don't await the connect future synchronously — the host-key prompt
      // is part of the same await chain. Fire-and-forget; we'll observe state.
      final connectFuture = controller.connect(SshConnectParams(
        host: host,
        port: port,
        username: user,
        auth: const SshAuth.password(pass),
      ));

      await autoAccept.timeout(const Duration(seconds: 10),
          onTimeout: () => fail('Never reached awaitingHostKey'));
      await connectFuture.timeout(const Duration(seconds: 15));

      // Drain any pending stream events so `transitions` includes the
      // `connected` emit that happens right before `connect()` returns.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.data.state, SshSessionState.connected,
          reason: 'expected connected, got '
              '${controller.data.state} (err=${controller.data.error})');
      expect(controller.data.remoteVersion, isNotNull);
      expect(controller.data.remoteVersion, contains('SSH-'));
      expect(
        transitions,
        containsAllInOrder(<SshSessionState>[
          SshSessionState.connecting,
          SshSessionState.awaitingHostKey,
          SshSessionState.authenticating,
          SshSessionState.connected,
        ]),
        reason: 'state transitions in unexpected order: $transitions',
      );

      // Host-key store should now contain a trusted entry.
      expect(controller.hostKeyStore.isTrusted(host, port,
          controller.hostKeyStore.trustedFingerprint(host, port)!), isTrue);

      // Disconnect cleanly.
      await controller.disconnect();
      expect(controller.data.state, SshSessionState.disconnected);

      await sub.cancel();
      await controller.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('rejecting host key produces failed state', () async {
      final controller = SshSessionController();

      // Subscribe BEFORE connecting — controller.stream is a broadcast
      // stream, so an early `firstWhere` would miss the awaitingHostKey
      // emission that fires during the `unawaited(connect)` microtask burst.
      final awaitingHostKey = Completer<void>();
      final terminalState = Completer<void>();
      final sub = controller.stream.listen((d) {
        if (d.state == SshSessionState.awaitingHostKey &&
            !awaitingHostKey.isCompleted) {
          awaitingHostKey.complete();
        }
        if ((d.state == SshSessionState.failed ||
                d.state == SshSessionState.disconnected) &&
            !terminalState.isCompleted) {
          terminalState.complete();
        }
      });

      unawaited(controller.connect(SshConnectParams(
        host: host,
        port: port,
        username: user,
        auth: const SshAuth.password(pass),
      )));

      await awaitingHostKey.future.timeout(const Duration(seconds: 10));
      controller.rejectHostKey();
      await terminalState.future.timeout(const Duration(seconds: 10));

      expect(controller.data.state, SshSessionState.failed);
      expect(controller.data.error, contains('rejected'));

      await sub.cancel();
      await controller.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
