// Machine-paced phase timeout tests (#542, #563).
//
// `connect()` bounds only the TCP connect (`handshakeTimeout`). After TCP
// opens, `await client.authenticated` had no timeout — a half-open Tailscale
// path (TCP SYN accepted, no SSH KEX bytes ever flow) hung at `connecting`
// forever. The controller arms a `readyTimeout` timer for the machine-paced
// phases and force-fails if they never complete.
//
// #542: bounds `connecting` (handshake / KEX never completes).
// #563: bounds `authenticating` too — a userauth that stalls AFTER host-key
//       accept previously hung forever, because the timer was cancelled on
//       entry to `authenticating` and never re-armed.
//
// BUT the timer must be cancelled the instant state enters `awaitingHostKey`,
// so the human-paced host-key prompt is never timed out.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';

/// A socket that "opens" successfully but never emits any data and never
/// closes — models the half-open path where SSH key exchange never completes.
class _SilentSocket implements SSHSocket {
  final _streamCtrl = StreamController<Uint8List>();
  final _sinkCtrl = StreamController<List<int>>();
  final _doneCompleter = Completer<void>();
  bool destroyed = false;

  @override
  Stream<Uint8List> get stream => _streamCtrl.stream;

  @override
  StreamSink<List<int>> get sink => _sinkCtrl.sink;

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> close() {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
    return done;
  }

  @override
  void destroy() {
    destroyed = true;
    if (!_streamCtrl.isClosed) _streamCtrl.close();
    if (!_sinkCtrl.isClosed) _sinkCtrl.close();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }
}

void main() {
  group('SshSessionController connecting-phase handshake timeout (#542)', () {
    test('readyTimeout defaults to 25 seconds', () {
      final controller = SshSessionController();
      expect(controller.readyTimeout, const Duration(seconds: 25));
      controller.dispose();
    });

    test(
      'socket opens but KEX never completes → fails within readyTimeout',
      () async {
        final controller = SshSessionController(
          readyTimeout: const Duration(milliseconds: 150),
          socketOpener: (host, port, {timeout}) async => _SilentSocket(),
        );

        final connectFuture = controller.connect(
          const SshConnectParams(
            host: 'half-open',
            port: 22,
            username: 'u',
            auth: SshAuth.password('p'),
          ),
        );

        // Reaches `connecting` synchronously after the socket opens.
        // Wait past the readyTimeout — the timer must fire and force-fail.
        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(controller.data.state, SshSessionState.failed);
        expect(controller.data.error, isNotNull);
        expect(controller.data.error, contains('No SSH response'));

        // connect() should not hang forever on `client.authenticated`.
        await connectFuture.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );

        await controller.dispose();
      },
    );

    test(
      'unreachable host (TCP connect refused) → failed within readyTimeout (#648)',
      () async {
        // Connecting to an unreachable host (down / wrong port → ECONNREFUSED,
        // bad host → no route) must deterministically reach `failed` with a
        // meaningful error, never a silent indefinite hang. The TCP connect
        // itself throws; the controller surfaces `failed` immediately, well
        // within the readyTimeout bound.
        final controller = SshSessionController(
          readyTimeout: const Duration(milliseconds: 200),
          socketOpener: (host, port, {timeout}) async {
            throw Exception(
              'Connection refused (errno = 111) — no route to host',
            );
          },
        );

        final connectFuture = controller.connect(
          const SshConnectParams(
            host: 'down.example',
            port: 22,
            username: 'u',
            auth: SshAuth.password('p'),
          ),
        );

        // Resolves fast (TCP throw) — assert it completes inside the bound and
        // the state is `failed` with a non-empty error.
        await connectFuture.timeout(
          const Duration(milliseconds: 150),
          onTimeout: () {},
        );

        expect(controller.data.state, SshSessionState.failed);
        expect(controller.data.error, isNotNull);
        expect(controller.data.error, contains('TCP connect failed'));

        await controller.dispose();
      },
    );

    test(
      'awaitingHostKey (host-key prompt) cancels the timer — never times out',
      () async {
        final controller = SshSessionController(
          readyTimeout: const Duration(milliseconds: 100),
        );

        const params = SshConnectParams(
          host: 'prompt-host',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        );

        // Drive the verify-host-key path directly (untrusted key → prompt).
        // The returned future stays pending until accept/reject — modelling a
        // human deliberating at the Trust dialog.
        final verifyFuture = controller.verifyHostKeyForTest(
          params,
          'ssh-ed25519',
          Uint8List.fromList(List<int>.filled(32, 7)),
        );

        expect(controller.data.state, SshSessionState.awaitingHostKey);

        // Wait far longer than the readyTimeout. A human at the dialog must NOT
        // be timed out — the connecting-phase timer must have been cancelled.
        await Future<void>.delayed(const Duration(milliseconds: 350));

        expect(controller.data.state, SshSessionState.awaitingHostKey);
        expect(controller.data.state, isNot(SshSessionState.failed));

        // Resolve the prompt so the pending future doesn't leak.
        controller.acceptHostKey();
        await verifyFuture;

        await controller.dispose();
      },
    );

    test(
      'authenticating stalls after host-key accept → fails within readyTimeout (#563)',
      () async {
        final controller = SshSessionController(
          readyTimeout: const Duration(milliseconds: 150),
        );

        const params = SshConnectParams(
          host: 'stall-auth',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        );

        // Untrusted key → prompt. The returned future stays pending until
        // accept/reject (models the dartssh2 verify callback awaiting a human).
        final verifyFuture = controller.verifyHostKeyForTest(
          params,
          'ssh-ed25519',
          Uint8List.fromList(List<int>.filled(32, 9)),
        );

        expect(controller.data.state, SshSessionState.awaitingHostKey);

        // Human accepts the host key → transition to `authenticating`. Now
        // userauth begins. Model a stalled userauth: nothing else happens — no
        // password challenge resolves, no transport bytes flow. Before #563 the
        // readyTimer was cancelled on entry to `authenticating` and never
        // re-armed, so the session hung in `authenticating` forever.
        controller.acceptHostKey();
        expect(controller.data.state, SshSessionState.authenticating);

        // Wait well past the readyTimeout. The re-armed timer must fire and
        // force-fail the stalled auth.
        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(controller.data.state, SshSessionState.failed);
        expect(controller.data.error, isNotNull);
        expect(controller.data.error, contains('No SSH response'));

        // Resolve the dangling verify future so it doesn't leak.
        await verifyFuture;

        await controller.dispose();
      },
    );

    test(
      'already-trusted host key → authenticating arms timer; stall → fails (#563)',
      () async {
        const params = SshConnectParams(
          host: 'trusted-stall',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        );

        final controller = SshSessionController(
          readyTimeout: const Duration(milliseconds: 150),
        );

        // Pre-trust the fingerprint so the verify path goes straight to
        // `authenticating` (no prompt). The hex must match _fingerprintHex of
        // the bytes below: 32 bytes of 0x05 → "05" * 32.
        final fp = Uint8List.fromList(List<int>.filled(32, 5));
        const hex =
            '0505050505050505050505050505050505050505050505050505050505050505';
        controller.hostKeyStore.trust(params.host, params.port, hex);

        final verifyFuture = controller.verifyHostKeyForTest(
          params,
          'ssh-ed25519',
          fp,
        );

        // Trusted → straight to authenticating (no awaitingHostKey detour).
        expect(controller.data.state, SshSessionState.authenticating);

        // Stalled userauth: wait past the readyTimeout.
        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(controller.data.state, SshSessionState.failed);

        await verifyFuture;
        await controller.dispose();
      },
    );
  });
}
