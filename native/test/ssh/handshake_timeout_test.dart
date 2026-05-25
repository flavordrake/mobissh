// Connecting-phase handshake-timeout tests (#542).
//
// `connect()` bounds only the TCP connect (`handshakeTimeout`). After TCP
// opens, `await client.authenticated` had no timeout — a half-open Tailscale
// path (TCP SYN accepted, no SSH KEX bytes ever flow) hung at `connecting`
// forever. The controller now arms a `readyTimeout` timer when it enters
// `connecting` and force-fails if KEX never completes — BUT the timer must be
// cancelled the instant state leaves `connecting`, so the human-paced host-key
// prompt (`awaitingHostKey`) is never timed out.

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

      final connectFuture = controller.connect(const SshConnectParams(
        host: 'half-open',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ));

      // Reaches `connecting` synchronously after the socket opens.
      // Wait past the readyTimeout — the timer must fire and force-fail.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(controller.data.state, SshSessionState.failed);
      expect(controller.data.error, isNotNull);
      expect(controller.data.error, contains('No SSH response'));

      // connect() should not hang forever on `client.authenticated`.
      await connectFuture.timeout(const Duration(seconds: 2),
          onTimeout: () {});

      await controller.dispose();
    });

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
    });
  });
}
