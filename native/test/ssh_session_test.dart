// State-machine tests for SshSessionController.
//
// Phase 1 (#501): hand-rolled fake socket lets us exercise the state
// transitions without standing up a real SSH server (that's
// `ssh_connect_integration_test.dart`).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

    test(
      'TCP connect failure transitions idle -> connecting -> failed',
      () async {
        final controller = SshSessionController(
          socketOpener: (host, port, {timeout}) async {
            throw Exception('boom (no network in unit test)');
          },
        );
        final transitions = <SshSessionState>[];
        final sub = controller.stream.listen((d) => transitions.add(d.state));

        await controller.connect(
          const SshConnectParams(
            host: 'unreachable',
            port: 22,
            username: 'nobody',
            auth: SshAuth.password('x'),
          ),
        );

        // Allow microtasks to drain.
        await Future<void>.delayed(Duration.zero);

        expect(transitions, contains(SshSessionState.connecting));
        expect(transitions.last, SshSessionState.failed);
        expect(controller.data.error, contains('TCP connect failed'));

        await sub.cancel();
        await controller.dispose();
      },
    );

    test(
      'key-auth with an unparseable key fails fast WITHOUT opening a socket',
      () async {
        // The device key-auth hang: a wrong passphrase / mangled key made
        // SSHKeyPair.fromPem throw, _identitiesFor swallowed it to null, key auth
        // had no password fallback, and `authenticated` hung forever. The fix
        // parses the key up-front and fails loudly — never reaching the socket.
        var openerCalls = 0;
        final controller = SshSessionController(
          socketOpener: (host, port, {timeout}) async {
            openerCalls += 1;
            throw Exception(
              'socket should not be opened for an unparseable key',
            );
          },
        );
        final transitions = <SshSessionState>[];
        final sub = controller.stream.listen((d) => transitions.add(d.state));

        await controller.connect(
          SshConnectParams(
            host: 'h',
            port: 22,
            username: 'u',
            auth: SshAuth.key(
              Uint8List.fromList(
                utf8.encode('this is not a valid private key'),
              ),
              passphrase: 'whatever',
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(transitions.last, SshSessionState.failed);
        expect(controller.data.error, contains('private key'));
        expect(
          openerCalls,
          0,
          reason:
              'must fail before opening a socket when the key is unparseable',
        );

        await sub.cancel();
        await controller.dispose();
      },
    );

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
      unawaited(
        controller.connect(
          const SshConnectParams(
            host: 'h',
            port: 22,
            username: 'u',
            auth: SshAuth.password('p'),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.data.state, SshSessionState.connecting);

      await controller.connect(
        const SshConnectParams(
          host: 'h',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
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
      final store = HostKeyStore(backend: InMemoryHostKeyBackend());
      final controller = SshSessionController(hostKeyStore: store);
      expect(identical(controller.hostKeyStore, store), isTrue);
      controller.dispose();
    });

    test('verify on an already-trusted host skips the prompt '
        '(connecting -> authenticating, NO awaitingHostKey) — #565', () async {
      const params = SshConnectParams(
        host: 'trusted.example',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      );
      // Seed persisted trust for the exact fingerprint the verify path will
      // compute from these bytes (hex of [0xDE,0xAD,0xBE,0xEF]).
      final backend = InMemoryHostKeyBackend(<String, String>{
        'trusted.example:22': 'deadbeef',
      });
      final store = HostKeyStore(backend: backend);
      await store.ready;

      final controller = SshSessionController(hostKeyStore: store);
      final transitions = <SshSessionState>[];
      final sub = controller.stream.listen((d) => transitions.add(d.state));

      final trusted = await controller.verifyHostKeyForTest(
        params,
        'ssh-ed25519',
        Uint8List.fromList(<int>[0xDE, 0xAD, 0xBE, 0xEF]),
      );

      expect(trusted, isTrue, reason: 'persisted-trust host must not prompt');
      expect(controller.data.state, SshSessionState.authenticating);
      expect(controller.data.pendingHostKey, isNull);
      expect(
        transitions,
        isNot(contains(SshSessionState.awaitingHostKey)),
        reason: 'a trusted host must NEVER enter the prompt state (#565)',
      );

      await sub.cancel();
      await controller.dispose();
    });

    test(
      'verify on an UNtrusted host still prompts (awaitingHostKey) — #565 guard',
      () async {
        const params = SshConnectParams(
          host: 'new.example',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        );
        final store = HostKeyStore(backend: InMemoryHostKeyBackend());
        final controller = SshSessionController(hostKeyStore: store);

        // ignore: unawaited_futures
        controller.verifyHostKeyForTest(
          params,
          'ssh-ed25519',
          Uint8List.fromList(<int>[0x01, 0x02]),
        );
        // Let the awaited ready + emit settle.
        await Future<void>.delayed(Duration.zero);

        expect(controller.data.state, SshSessionState.awaitingHostKey);
        expect(controller.data.pendingHostKey, isNotNull);

        // Resolve the pending completer so it doesn't leak past teardown.
        controller.rejectHostKey();
        await controller.dispose();
      },
    );

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

  // ---------------------------------------------------------------------
  // #551 seamless reconnect: soft_disconnected, unreachable classification,
  // variable backoff, max-attempts ceiling.
  // ---------------------------------------------------------------------
  group('SshSessionController #551 reconnect policy', () {
    SshConnectParams params() => const SshConnectParams(
      host: 'example',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    );

    test('exponential backoff progression for transient (non-unreachable)', () {
      final c = SshSessionController(
        reconnectDelay: const Duration(seconds: 2),
      );
      // attempt is 0-based; base 2s, factor 1.5, cap 30s.
      expect(
        c.reconnectDelayFor(0, unreachable: false),
        const Duration(milliseconds: 2000),
      );
      expect(
        c.reconnectDelayFor(1, unreachable: false),
        const Duration(milliseconds: 3000),
      );
      expect(
        c.reconnectDelayFor(2, unreachable: false),
        const Duration(milliseconds: 4500),
      );
      expect(
        c.reconnectDelayFor(3, unreachable: false),
        const Duration(milliseconds: 6750),
      );
      // Far out — must be capped at 30s, never exceed.
      expect(
        c.reconnectDelayFor(20, unreachable: false),
        const Duration(seconds: 30),
      );
      c.dispose();
    });

    test('unreachable uses a fixed 1.5s interval regardless of attempt', () {
      final c = SshSessionController();
      expect(
        c.reconnectDelayFor(0, unreachable: true),
        const Duration(milliseconds: 1500),
      );
      expect(
        c.reconnectDelayFor(5, unreachable: true),
        const Duration(milliseconds: 1500),
      );
      expect(
        c.reconnectDelayFor(40, unreachable: true),
        const Duration(milliseconds: 1500),
      );
      c.dispose();
    });

    test('isUnreachableError matches host-unreachable patterns', () {
      // errno-coded socket errors
      expect(
        SshSessionController.isUnreachableError(
          SSHSocketError(
            const SocketException(
              'No route to host',
              osError: OSError('No route to host', 113),
            ),
          ),
        ),
        isTrue,
      );
      expect(
        SshSessionController.isUnreachableError(
          SSHSocketError(
            const SocketException(
              'Connection refused',
              osError: OSError('Connection refused', 111),
            ),
          ),
        ),
        isTrue,
      );
      // message-pattern errors (no concrete errno)
      expect(
        SshSessionController.isUnreachableError(
          SSHSocketError('host unreachable'),
        ),
        isTrue,
      );
      expect(
        SshSessionController.isUnreachableError(
          Exception('No SSH response in 25s — host may be unreachable'),
        ),
        isTrue,
      );
      // a plain reset/abort is transient but NOT unreachable
      expect(
        SshSessionController.isUnreachableError(
          SSHSocketError(
            const SocketException('reset', osError: OSError('reset', 104)),
          ),
        ),
        isFalse,
      );
    });

    test(
      'unreachable close sets lastErrorUnreachable + retries at 1.5s ceiling 60',
      () async {
        var attempts = 0;
        final c = SshSessionController(
          reconnectDelay: Duration.zero,
          // Drive the fixed-interval unreachable retry synchronously.
          unreachableReconnectInterval: Duration.zero,
          reconnectAttemptOverride: (_) async {
            attempts += 1;
            return false; // keep failing
          },
        );
        c.debugSetConnectedForTest(params());

        c.handleTransportClosed(
          SSHSocketError(
            const SocketException(
              'No route to host',
              osError: OSError('No route to host', 113),
            ),
          ),
        );

        // Drain. With Duration.zero delays the loop runs fast; cap iterations.
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(Duration.zero);
          if (c.data.state == SshSessionState.failed) break;
        }

        expect(
          c.lastErrorUnreachable,
          isTrue,
          reason: 'unreachable host must set the flag for the audit screen',
        );
        // Unreachable ceiling is 60 — more attempts than the default transient 10.
        expect(
          attempts,
          greaterThan(10),
          reason: 'unreachable retries up to 60, well beyond transient 10',
        );
        expect(c.data.state, SshSessionState.failed);
        await c.dispose();
      },
    );

    test(
      'non-unreachable transient does NOT set lastErrorUnreachable',
      () async {
        final c = SshSessionController(
          reconnectDelay: Duration.zero,
          maxReconnectAttempts: 2,
          reconnectAttemptOverride: (_) async => false,
        );
        c.debugSetConnectedForTest(params());
        c.handleTransportClosed(
          SSHSocketError(
            const SocketException('reset', osError: OSError('reset', 104)),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(c.lastErrorUnreachable, isFalse);
        expect(c.data.state, SshSessionState.failed);
        await c.dispose();
      },
    );

    test('clean server-initiated close while connected emits soft_disconnected '
        'then auto-reconnects', () async {
      final states = <SshSessionState>[];
      final c = SshSessionController(
        reconnectDelay: Duration.zero,
        reconnectAttemptOverride: (_) async => true, // reconnect succeeds
      );
      final sub = c.stream.listen((d) => states.add(d.state));
      c.debugSetConnectedForTest(params());

      // Clean close (server sent SSH_MSG_DISCONNECT) — error == null.
      c.handleTransportClosed(null);

      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
        if (c.data.state == SshSessionState.connected) break;
      }

      expect(
        states,
        contains(SshSessionState.softDisconnected),
        reason:
            'clean disconnect while connected must surface soft_disconnected',
      );
      expect(states, contains(SshSessionState.reconnecting));
      expect(c.data.state, SshSessionState.connected);
      await sub.cancel();
      await c.dispose();
    });

    test(
      'clean close while NOT connected stays disconnected (no reconnect)',
      () async {
        var reconnectCalled = false;
        final c = SshSessionController(
          reconnectDelay: Duration.zero,
          reconnectAttemptOverride: (_) async {
            reconnectCalled = true;
            return true;
          },
        );
        // Seed a non-connected state via failed-then-idle path: start idle.
        c.handleTransportClosed(null);
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(reconnectCalled, isFalse);
        await c.dispose();
      },
    );

    test('transient retry max-attempts ceiling surfaces failed', () async {
      final c = SshSessionController(
        reconnectDelay: Duration.zero,
        maxReconnectAttempts: 3,
        reconnectAttemptOverride: (_) async => false,
      );
      c.debugSetConnectedForTest(params());
      c.handleTransportClosed(
        SSHSocketError(
          const SocketException('reset', osError: OSError('reset', 104)),
        ),
      );
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(c.data.state, SshSessionState.failed);
      expect(c.data.error, contains('reconnect'));
      await c.dispose();
    });
  });
}
