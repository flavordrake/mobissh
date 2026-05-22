// State-machine tests for SshSessionController.
//
// Phase 1 (#501): hand-rolled fake socket lets us exercise the state
// transitions without standing up a real SSH server (that's
// `ssh_connect_integration_test.dart`).

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/host_key_store.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';

void main() {
  group('SshSessionController state machine', () {
    test('initial state is idle', () {
      final controller = SshSessionController();
      expect(controller.data.state, SshSessionState.idle);
      expect(controller.data.error, isNull);
      expect(controller.data.pendingHostKey, isNull);
      controller.dispose();
    });

    test('TCP connect failure transitions idle -> connecting -> failed',
        () async {
      final controller = SshSessionController(
        socketOpener: (host, port, {timeout}) async {
          throw Exception('boom (no network in unit test)');
        },
      );
      final transitions = <SshSessionState>[];
      final sub = controller.stream.listen((d) => transitions.add(d.state));

      await controller.connect(const SshConnectParams(
        host: 'unreachable',
        port: 22,
        username: 'nobody',
        auth: SshAuth.password('x'),
      ));

      // Allow microtasks to drain.
      await Future<void>.delayed(Duration.zero);

      expect(transitions, contains(SshSessionState.connecting));
      expect(transitions.last, SshSessionState.failed);
      expect(controller.data.error, contains('TCP connect failed'));

      await sub.cancel();
      await controller.dispose();
    });

    test('connect is a no-op when already connecting', () async {
      // Use a socket opener that never resolves to wedge the controller in
      // `connecting`. The second connect call should bail out immediately.
      final firstOpener = Completer<SSHSocket>();
      var openerCalls = 0;
      final controller = SshSessionController(
        socketOpener: (host, port, {timeout}) {
          openerCalls += 1;
          return firstOpener.future;
        },
      );

      // Don't await — let it park in connecting.
      unawaited(controller.connect(const SshConnectParams(
        host: 'h',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      )));
      await Future<void>.delayed(Duration.zero);
      expect(controller.data.state, SshSessionState.connecting);

      await controller.connect(const SshConnectParams(
        host: 'h',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));
      expect(openerCalls, 1, reason: 'second connect must not call opener');

      // Drain the parked operation so the controller cleans up.
      firstOpener.completeError(StateError('shutdown'));
      await Future<void>.delayed(Duration.zero);
      await controller.dispose();
    });

    test('acceptHostKey is a no-op when no pending prompt', () {
      final controller = SshSessionController();
      // Should not throw or transition.
      controller.acceptHostKey();
      expect(controller.data.state, SshSessionState.idle);
      controller.dispose();
    });

    test('rejectHostKey is a no-op when no pending prompt', () {
      final controller = SshSessionController();
      controller.rejectHostKey();
      expect(controller.data.state, SshSessionState.idle);
      controller.dispose();
    });

    test('disconnect from idle transitions to disconnected', () async {
      final controller = SshSessionController();
      await controller.disconnect();
      expect(controller.data.state, SshSessionState.disconnected);
      await controller.dispose();
    });

    test('hostKeyStore is exposed for inspection', () {
      final store = HostKeyStore();
      final controller = SshSessionController(hostKeyStore: store);
      expect(identical(controller.hostKeyStore, store), isTrue);
      controller.dispose();
    });

    test('SshSessionData.copyWith respects clear flags', () {
      const data = SshSessionData(
        state: SshSessionState.failed,
        error: 'bad',
        banner: 'hi',
      );
      final cleared = data.copyWith(
        state: SshSessionState.idle,
        clearError: true,
        clearBanner: true,
      );
      expect(cleared.state, SshSessionState.idle);
      expect(cleared.error, isNull);
      expect(cleared.banner, isNull);
    });

    // NOTE: Wiring a fake SSHSocket through dartssh2 to assert the full
    // handshake state machine would require either re-implementing the SSH
    // version-exchange or adopting `mocktail`. Phase 1 punts on this — the
    // real handshake is covered by `ssh_connect_integration_test.dart`
    // against test-sshd, and the TCP-failure path above covers the
    // connecting -> failed transition.
  });
}
