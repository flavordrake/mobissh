// #986 — user-intent disconnect bit lifecycle across disconnect/reconnect.
//
// The #838 debug invariant (`_assertSuppressConsistent`) fired on every user
// disconnect of a LIVE session: `disconnect()` set the bit, closed the client,
// and only emitted `disconnected` AFTER `await client.done` — but the client's
// done-handler (wired in `connect()`, registered earlier on the same future)
// ran FIRST, observing bit=true while state was still `connected`. Besides the
// assert spam, the clean-close path re-armed a spurious softDisconnected →
// reconnecting hop, and the disconnect-cause classifier mislabeled.
//
// Second hole: a user disconnect racing an in-flight `connect()` (parked at
// the socket-open await) let the zombie connect keep going and resurrect a
// session the user had closed (#1020: user-closed stays closed).
//
// These tests pin: (A) live-client disconnect never violates the invariant or
// re-arms reconnect, (B) a mid-connect user disconnect aborts the connect,
// (C) disconnect → reconnectNow clears the bit and reconnects cleanly,
// (D) an involuntary drop keeps the bit false throughout auto-reconnect,
// (E) a user disconnect without any reconnect keeps the bit set.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

/// A fake transport socket: never emits, records what was written, and
/// completes `done` on destroy. Mirrors `_SilentSocket` in
/// handshake_timeout_test.dart plus a written-bytes recorder.
class _FakeSocket implements SSHSocket {
  _FakeSocket() {
    _sinkCtrl.stream.listen(sank.add);
  }

  final _streamCtrl = StreamController<Uint8List>();
  final _sinkCtrl = StreamController<List<int>>();
  final _doneCompleter = Completer<void>();

  /// Everything the client wrote to the wire.
  final sank = <List<int>>[];
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

Future<void> _pump([int turns = 8]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('#986 user disconnect of a LIVE session (stale done-handler)', () {
    test(
      'disconnect drives `disconnected` before the client teardown — the '
      'done-handler never sees bit=true+connected (no assert, no re-arm)',
      () async {
        final controller = SshSessionController(reconnectDelay: Duration.zero);
        controller.debugSetConnectedForTest(_params);

        final socket = _FakeSocket();
        final client = SSHClient(
          socket,
          username: 'u',
          onPasswordRequest: () => 'p',
        );
        controller.debugAttachClientForTest(client);
        // Mirror connect()'s production done wiring: this handler registers on
        // client.done BEFORE disconnect()'s own await, so it runs first when
        // the future resolves — exactly the window the bug lived in.
        unawaited(
          client.done
              .then((_) => controller.handleTransportClosed(null))
              .catchError((Object e) {
            controller.handleTransportClosed(e);
          }),
        );

        final states = <SshSessionState>[];
        final sub = controller.stream.listen((d) => states.add(d.state));

        await controller.disconnect();
        await _pump();

        expect(controller.data.state, SshSessionState.disconnected);
        expect(controller.userInitiatedDisconnect, isTrue);
        expect(
          states,
          isNot(contains(SshSessionState.softDisconnected)),
          reason: 'the stale clean-close must not re-arm a user disconnect',
        );
        expect(states, isNot(contains(SshSessionState.reconnecting)));

        await sub.cancel();
        await controller.dispose();
      },
    );
  });

  group('#986 user disconnect racing an in-flight connect()', () {
    test(
      'disconnect while connect() is parked at socket-open aborts the '
      'connect — the user-closed session is never resurrected',
      () async {
        final gate = Completer<SSHSocket>();
        final controller = SshSessionController(
          socketOpener: (host, port, {timeout}) => gate.future,
        );

        final connectFuture = controller.connect(_params);
        await _pump(2);
        expect(controller.data.state, SshSessionState.connecting);

        await controller.disconnect();
        expect(controller.data.state, SshSessionState.disconnected);
        expect(controller.userInitiatedDisconnect, isTrue);

        // The socket opens AFTER the user disconnected. Without the abort the
        // zombie connect builds an SSHClient over it and starts the handshake.
        final socket = _FakeSocket();
        gate.complete(socket);
        await connectFuture.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        await _pump();

        expect(controller.data.state, SshSessionState.disconnected);
        expect(controller.userInitiatedDisconnect, isTrue);
        expect(
          socket.sank,
          isEmpty,
          reason: 'no SSH bytes may flow on a session the user closed',
        );
        expect(socket.destroyed, isTrue);

        await controller.dispose();
      },
    );

    test(
      'disconnect while connect() is parked at socket-open, opener then '
      'FAILS — the user\'s `disconnected` is not overwritten with `failed`',
      () async {
        final gate = Completer<SSHSocket>();
        final controller = SshSessionController(
          socketOpener: (host, port, {timeout}) => gate.future,
        );

        final connectFuture = controller.connect(_params);
        await _pump(2);
        expect(controller.data.state, SshSessionState.connecting);

        await controller.disconnect();

        gate.completeError(const SocketException('refused'));
        await connectFuture.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        await _pump();

        expect(controller.data.state, SshSessionState.disconnected);
        expect(controller.userInitiatedDisconnect, isTrue);

        await controller.dispose();
      },
    );
  });

  group('#986 bit lifecycle across reconnect', () {
    test(
      'user disconnect → reconnectNow: bit clears, session reaches connected, '
      'invariant holds at every call site',
      () async {
        final controller = SshSessionController(
          reconnectDelay: Duration.zero,
          reconnectAttemptOverride: (_) async => true,
        );
        controller.debugSetConnectedForTest(_params);

        await controller.disconnect();
        expect(controller.userInitiatedDisconnect, isTrue);
        expect(controller.data.state, SshSessionState.disconnected);

        controller.reconnectNow();
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
          if (controller.data.state == SshSessionState.connected) break;
        }

        expect(controller.data.state, SshSessionState.connected);
        expect(
          controller.userInitiatedDisconnect,
          isFalse,
          reason: 'a new connect clears the user-intent bit',
        );

        // Exercise an invariant call site while connected — must not throw.
        await controller.resumeReconnectIfStale(staleThreshold: Duration.zero);
        expect(controller.data.state, SshSessionState.connected);

        await controller.dispose();
      },
    );

    test('involuntary drop → auto-reconnect keeps the bit false throughout',
        () async {
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        reconnectAttemptOverride: (_) async => true,
      );
      controller.debugSetConnectedForTest(_params);

      controller.handleTransportClosed(
        SSHSocketError(
          const SocketException('reset', osError: OSError('reset', 104)),
        ),
      );
      expect(controller.userInitiatedDisconnect, isFalse);

      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
        if (controller.data.state == SshSessionState.connected) break;
      }

      expect(controller.data.state, SshSessionState.connected);
      expect(controller.userInitiatedDisconnect, isFalse);

      await controller.dispose();
    });

    test('user disconnect WITHOUT reconnect keeps the bit set', () async {
      final controller = SshSessionController(reconnectDelay: Duration.zero);
      controller.debugSetConnectedForTest(_params);

      await controller.disconnect();
      await _pump();

      expect(controller.data.state, SshSessionState.disconnected);
      expect(controller.userInitiatedDisconnect, isTrue);

      await controller.dispose();
    });
  });
}
