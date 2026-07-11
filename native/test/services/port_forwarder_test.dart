// Port-forward engine tests (#1047).
//
// Exercises the task-side ssh -L listener in isolation: a real dart:io
// ServerSocket on 127.0.0.1 with a FAKE tunnel opener standing in for the
// dartssh2 direct-tcpip channel (`SSHClient.forwardLocal` returns an
// `SSHSocket`; the fake implements the same interface). Covers:
//   - accept → bidirectional pipe (echo round-trip)
//   - close → subsequent connects refused + live pipes torn down
//   - port-in-use bind failure surfaces as a SocketException
//   - channel-open refusal closes the accepted socket, keeps listening
//     (ssh -L semantics), and reports via onChannelError

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSocket;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/port_forwarder.dart';

/// A fake direct-tcpip tunnel that ECHOES everything written to its sink back
/// out of its stream — so a local socket round-trip proves both pipe
/// directions work.
class _EchoTunnel implements SSHSocket {
  final _out = StreamController<Uint8List>();
  final _in = StreamController<List<int>>();
  final _done = Completer<void>();
  bool closed = false;

  _EchoTunnel() {
    _in.stream.listen(
      (data) {
        if (!_out.isClosed) {
          _out.add(data is Uint8List ? data : Uint8List.fromList(data));
        }
      },
      onDone: () {
        // Remote side sees our half-close: end the read stream too.
        if (!_out.isClosed) _out.close();
      },
    );
  }

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  StreamSink<List<int>> get sink => _in.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    closed = true;
    if (!_in.isClosed) await _in.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    closed = true;
    _in.close();
    if (!_out.isClosed) _out.close();
    if (!_done.isCompleted) _done.complete();
  }
}

Future<Uint8List> _roundTrip(int port, List<int> payload) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.add(payload);
  await socket.flush();
  final got = <int>[];
  final completer = Completer<Uint8List>();
  late StreamSubscription<Uint8List> sub;
  sub = socket.listen(
    (chunk) {
      got.addAll(chunk);
      if (got.length >= payload.length) {
        completer.complete(Uint8List.fromList(got));
        sub.cancel();
        socket.destroy();
      }
    },
    onDone: () {
      if (!completer.isCompleted) {
        completer.complete(Uint8List.fromList(got));
      }
      socket.destroy();
    },
  );
  return completer.future.timeout(const Duration(seconds: 5));
}

void main() {
  test('accept → bidirectional pipe: bytes echo through the tunnel', () async {
    final tunnels = <_EchoTunnel>[];
    final listener = await PortForwardListener.start(
      config: const PortForwardConfig(
        localPort: 0, // ephemeral for the test; prod uses the user's port
        remoteHost: '127.0.0.1',
        remotePort: 8088,
      ),
      openTunnel: (host, port) async {
        expect(host, '127.0.0.1');
        expect(port, 8088);
        final t = _EchoTunnel();
        tunnels.add(t);
        return t;
      },
    );
    addTearDown(listener.close);

    final payload = List<int>.generate(64, (i) => i);
    final echoed = await _roundTrip(listener.boundPort, payload);
    expect(echoed, payload);
    expect(tunnels.length, 1);
  });

  test('close → subsequent connects are refused + tunnels torn down', () async {
    final tunnels = <_EchoTunnel>[];
    final listener = await PortForwardListener.start(
      config: const PortForwardConfig(
        localPort: 0,
        remoteHost: '127.0.0.1',
        remotePort: 8088,
      ),
      openTunnel: (host, port) async {
        final t = _EchoTunnel();
        tunnels.add(t);
        return t;
      },
    );
    final port = listener.boundPort;
    // Prove it was live first (also creates a live tunnel to tear down).
    await _roundTrip(port, [1, 2, 3]);

    await listener.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      () => Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<SocketException>()),
    );
    expect(
      tunnels.every((t) => t.closed),
      isTrue,
      reason: 'live tunnels must be torn down with the listener',
    );
  });

  test('port-in-use bind failure throws SocketException', () async {
    final squatter = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(squatter.close);
    expect(
      () => PortForwardListener.start(
        config: PortForwardConfig(
          localPort: squatter.port,
          remoteHost: '127.0.0.1',
          remotePort: 8088,
        ),
        openTunnel: (_, _) async => _EchoTunnel(),
      ),
      throwsA(isA<SocketException>()),
    );
  });

  test(
    'channel-open refusal closes THAT socket, keeps listening, reports error',
    () async {
      final errors = <String>[];
      var attempts = 0;
      final listener = await PortForwardListener.start(
        config: const PortForwardConfig(
          localPort: 0,
          remoteHost: '127.0.0.1',
          remotePort: 8088,
        ),
        openTunnel: (host, port) async {
          attempts += 1;
          if (attempts == 1) {
            throw Exception('channel open failed: administratively prohibited');
          }
          return _EchoTunnel();
        },
        onChannelError: errors.add,
      );
      addTearDown(listener.close);

      // First connection: tunnel refused → socket ends with no data.
      final refused = await _roundTrip(listener.boundPort, [9, 9, 9]);
      expect(refused, isEmpty, reason: 'refused channel must not echo bytes');
      expect(errors, isNotEmpty);
      expect(errors.first, contains('administratively prohibited'));

      // Listener survives (ssh -L keeps listening): the next connect pipes.
      final ok = await _roundTrip(listener.boundPort, [4, 5, 6]);
      expect(ok, [4, 5, 6]);
    },
  );
}
