// SessionHost port-forward routing tests (#1047).
//
// Exercises the task-side forward lifecycle end to end over the real IPC pair
// (InMemoryGatewayPair) with a REAL loopback ServerSocket and a fake tunnel
// opener injected via the host's `forwardOpenerFactory` seam — no real SSH.
// Covers the state-transition contract (per rules: test TRANSITIONS):
//   - forwardAdd before `connected` stores config (status starting, no bind)
//   - `connected` transition ARMS the listener (status active, bytes pipe)
//   - leaving `connected` drops the listener; re-entering RE-ARMS it (the
//     reconnect re-arm the issue requires)
//   - forwardRemove closes the listener → connection refused + empty list
//   - port-in-use bind failure surfaces as status error with a message
//
// Pattern lifted from reconnect_shell_revive_test.dart (drivable controller +
// silent-socket sentinel client).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';

class _SilentSocket implements SSHSocket {
  final _outbound = StreamController<List<int>>();
  final _doneCompleter = Completer<void>();

  @override
  Stream<Uint8List> get stream => const Stream<Uint8List>.empty();

  @override
  StreamSink<List<int>> get sink => _outbound.sink;

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> close() async {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
    await _outbound.close();
    return done;
  }

  @override
  void destroy() {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }
}

class _DrivableController extends SshSessionController {
  // The socketOpener never resolves: a real `connect('h':22)` would otherwise
  // fail DNS and drive connected → failed underneath the test's driven states.
  _DrivableController(this._client)
      : super(
          socketOpener: (host, port, {timeout}) {
            return Future.delayed(const Duration(days: 1), () {
              throw Exception('socketOpener not used in forward tests');
            });
          },
        );

  final SSHClient _client;

  @override
  SSHClient? get client => _client;
}

/// Echo tunnel — same as port_forwarder_test's, kept local for isolation.
class _EchoTunnel implements SSHSocket {
  final _out = StreamController<Uint8List>();
  final _in = StreamController<List<int>>();
  final _done = Completer<void>();

  _EchoTunnel() {
    _in.stream.listen(
      (data) {
        if (!_out.isClosed) {
          _out.add(data is Uint8List ? data : Uint8List.fromList(data));
        }
      },
      onDone: () {
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
    if (!_in.isClosed) await _in.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    _in.close();
    if (!_out.isClosed) _out.close();
    if (!_done.isCompleted) _done.complete();
  }
}

const _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

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
      if (!completer.isCompleted) completer.complete(Uint8List.fromList(got));
      socket.destroy();
    },
  );
  return completer.future.timeout(const Duration(seconds: 5));
}

/// Pick a free loopback port by binding an ephemeral socket and releasing it.
Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

typedef _Ctx = ({
  SessionHost host,
  SshSessionProxy proxy,
  InMemoryGatewayPair pair,
  _DrivableController Function() controllerOf,
  List<List<ForwardInfo>> lists,
});

Future<_Ctx> _setUp(String sid) async {
  final socket = _SilentSocket();
  final sentinelClient = SSHClient(socket, username: 'u');
  late _DrivableController controller;
  _DrivableController factory() {
    controller = _DrivableController(sentinelClient);
    return controller;
  }

  final pair = InMemoryGatewayPair();
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: factory,
    forwardOpenerFactory: (sessionId) =>
        (remoteHost, remotePort) async => _EchoTunnel(),
    snapshotInterval: const Duration(hours: 1),
  );
  final proxy = SshSessionProxy(sessionId: sid, gateway: pair.uiSide);

  final lists = <List<ForwardInfo>>[];
  proxy.forwardEvents.listen(lists.add);

  addTearDown(() async {
    await proxy.dispose();
    await host.dispose();
    await pair.dispose();
    try {
      sentinelClient.close();
    } catch (_) {}
    socket.destroy();
  });

  proxy.connect(_params);
  await _settle();
  return (
    host: host,
    proxy: proxy,
    pair: pair,
    controllerOf: () => controller,
    lists: lists,
  );
}

void main() {
  test('forwardAdd before connected: config stored, arms on connected',
      () async {
    final ctx = await _setUp('sid-fwd-arm');
    final port = await _freePort();

    // Add while still idle (auth never completes on the silent socket).
    ctx.proxy.forwardAdd(
      localPort: port,
      remoteHost: '127.0.0.1',
      remotePort: 8088,
    );
    await _settle();

    expect(ctx.lists, isNotEmpty, reason: 'add must emit a forward list');
    expect(ctx.lists.last.single.status, ForwardStatus.starting,
        reason: 'not connected yet — nothing may bind');
    // Not listening yet.
    expect(
      () => Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<SocketException>()),
    );

    // Connected transition arms the listener.
    ctx.controllerOf().debugSetConnectedForTest(_params);
    await _settle();
    expect(ctx.lists.last.single.status, ForwardStatus.active);

    final echoed = await _roundTrip(port, [10, 20, 30]);
    expect(echoed, [10, 20, 30], reason: 'bytes must pipe through the tunnel');
  });

  test('leaving connected drops the listener; reconnect RE-ARMS it', () async {
    final ctx = await _setUp('sid-fwd-rearm');
    final port = await _freePort();

    ctx.controllerOf().debugSetConnectedForTest(_params);
    await _settle();
    ctx.proxy.forwardAdd(
      localPort: port,
      remoteHost: '127.0.0.1',
      remotePort: 8088,
    );
    await _settle();
    expect(ctx.lists.last.single.status, ForwardStatus.active);
    await _roundTrip(port, [1]);

    // Drop: the session leaves connected → listener must die with it.
    await ctx.controllerOf().disconnect();
    await _settle();
    expect(ctx.lists.last.single.status, ForwardStatus.starting,
        reason: 'forward dies with the session (config retained)');
    expect(
      () => Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<SocketException>()),
    );

    // Reconnect: re-entering connected re-arms the retained config.
    ctx.controllerOf().debugSetConnectedForTest(_params);
    await _settle();
    expect(ctx.lists.last.single.status, ForwardStatus.active,
        reason: 'profile/ad-hoc forwards re-arm on reconnect');
    final echoed = await _roundTrip(port, [7, 8]);
    expect(echoed, [7, 8]);
  });

  test('forwardRemove closes the listener → refused + empty list', () async {
    final ctx = await _setUp('sid-fwd-rm');
    final port = await _freePort();

    ctx.controllerOf().debugSetConnectedForTest(_params);
    await _settle();
    ctx.proxy.forwardAdd(
      localPort: port,
      remoteHost: '127.0.0.1',
      remotePort: 8088,
    );
    await _settle();
    await _roundTrip(port, [1, 2]);

    ctx.proxy.forwardRemove(port);
    await _settle();
    expect(ctx.lists.last, isEmpty);
    expect(
      () => Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<SocketException>()),
    );
  });

  test('port-in-use surfaces as status error with a message', () async {
    final ctx = await _setUp('sid-fwd-inuse');
    final squatter = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(squatter.close);

    ctx.controllerOf().debugSetConnectedForTest(_params);
    await _settle();
    ctx.proxy.forwardAdd(
      localPort: squatter.port,
      remoteHost: '127.0.0.1',
      remotePort: 8088,
    );
    await _settle();

    final info = ctx.lists.last.single;
    expect(info.status, ForwardStatus.error);
    expect(info.error, isNotNull);
    expect(info.error, contains('${squatter.port}'));
  });

  test('forwardList replays the current table on demand', () async {
    final ctx = await _setUp('sid-fwd-list');
    final port = await _freePort();
    ctx.proxy.forwardAdd(
      localPort: port,
      remoteHost: 'db.internal',
      remotePort: 5432,
    );
    await _settle();
    ctx.lists.clear();

    ctx.proxy.forwardList();
    await _settle();
    expect(ctx.lists, hasLength(1));
    final info = ctx.lists.single.single;
    expect(info.localPort, port);
    expect(info.remoteHost, 'db.internal');
    expect(info.remotePort, 5432);
  });
}
