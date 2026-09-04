// User-forced reconnect of a LIVE session (#1136, session-menu "Reconnect
// (force)").
//
// `reconnectNow()` (#817) deliberately no-ops on a `connected` session — it
// backs the Reconnect button on a DROPPED row. The session menu offers the same
// button on a connected session as a forced re-attach (mode resync after a
// background auto-reconnect, #881), and that path silently did nothing.
// `forceReconnect()` tears the live client down and re-enters the normal
// reconnect path; for a dropped session it delegates to `reconnectNow()`.
//
// The torn-down client's `done` future must NOT be mistaken for a drop of the
// NEW connection: the production done wiring ignores a stale client. Assert the
// externally-observable transitions only.

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

/// Silent transport socket whose `done` completes on close/destroy — mirrors
/// `_FakeSocket` in user_disconnect_reconnect_bit_test.dart.
class _FakeSocket implements SSHSocket {
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

Future<void> _settle(SshSessionController c, SshSessionState target) async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
    if (c.data.state == target) return;
  }
}

void main() {
  test(
    'forceReconnect on a CONNECTED session: connected → reconnecting → '
    'connected, old client torn down, its stale done ignored',
    () async {
      var attempts = 0;
      final controller = SshSessionController(
        reconnectDelay: Duration.zero,
        reconnectAttemptOverride: (_) async {
          attempts += 1;
          return true;
        },
      );
      controller.debugSetConnectedForTest(_params);
      final socket = _FakeSocket();
      final client = SSHClient(
        socket,
        username: 'u',
        onPasswordRequest: () => 'p',
      );
      controller.debugAttachClientForTest(client, wireDone: true);

      final states = <SshSessionState>[];
      final sub = controller.stream.listen((d) => states.add(d.state));

      controller.forceReconnect();
      await _settle(controller, SshSessionState.connected);

      expect(states.first, SshSessionState.reconnecting);
      expect(controller.data.state, SshSessionState.connected);
      expect(attempts, 1, reason: 'exactly one reconnect attempt ran');
      expect(socket.destroyed, isTrue, reason: 'the live transport is torn down');
      expect(
        states,
        isNot(contains(SshSessionState.disconnected)),
        reason: 'the torn-down client\'s done must not surface as a drop',
      );
      expect(states, isNot(contains(SshSessionState.softDisconnected)));
      expect(states, isNot(contains(SshSessionState.failed)));
      await sub.cancel();
      await controller.dispose();
    },
  );

  test('forceReconnect on a dropped session delegates to reconnectNow',
      () async {
    var attempts = 0;
    final controller = SshSessionController(
      reconnectDelay: Duration.zero,
      maxReconnectAttempts: 1,
      reconnectAttemptOverride: (_) async {
        attempts += 1;
        return attempts > 1;
      },
    );
    controller.debugSetConnectedForTest(_params);
    controller.handleTransportClosed(
      SSHSocketError(
        const SocketException('broken', osError: OSError('broken', 32)),
      ),
    );
    await _settle(controller, SshSessionState.failed);
    expect(controller.data.state, SshSessionState.failed);

    controller.forceReconnect();
    await _settle(controller, SshSessionState.connected);
    expect(controller.data.state, SshSessionState.connected);
    await controller.dispose();
  });

  test('a stale done from a torn-down client never touches the NEW client',
      () async {
    // Regression guard for the identity check in the done wiring: an old
    // client's late `done` (a real drop of the OLD socket) arriving after a
    // reconnect must not drive the reconnected session into a drop state.
    final controller = SshSessionController(reconnectDelay: Duration.zero);
    controller.debugSetConnectedForTest(_params);
    final oldSocket = _FakeSocket();
    final oldClient = SSHClient(
      oldSocket,
      username: 'u',
      onPasswordRequest: () => 'p',
    );
    controller.debugAttachClientForTest(oldClient, wireDone: true);
    // Swap in a new client (what connect() does after a reconnect attempt).
    final newClient = SSHClient(
      _FakeSocket(),
      username: 'u',
      onPasswordRequest: () => 'p',
    );
    controller.debugAttachClientForTest(newClient, wireDone: true);

    final states = <SshSessionState>[];
    final sub = controller.stream.listen((d) => states.add(d.state));
    oldSocket.destroy();
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(controller.data.state, SshSessionState.connected);
    expect(states, isEmpty, reason: 'stale done must emit no transition');
    await sub.cancel();
    await controller.dispose();
  });
}
