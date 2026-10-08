// #1285: tmux control mode is removed. With the old opt-in on, the host opened
// a `tmux -CC` exec channel and `_handleInput` wrote typed bytes to it, so
// anything typed ran as a tmux command (`run-shell` included).
//
// These tests pin that no input path can reach a tmux control channel any more:
//   - a connect that still carries the retired `controlMode: true` bit (an old
//     UI build, a stale command) opens the ordinary PTY shell, and typed input
//     lands there as terminal bytes;
//   - the retired control-command kinds (`controlCommand`, `tmuxGesture`,
//     `tmuxScroll`) are rejected as unknown, and nothing is written anywhere.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_shell.dart';

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
  Future<void> flush() async {}

  @override
  void destroy() {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }
}

class _DrivableController extends SshSessionController {
  _DrivableController(this._client);
  final SSHClient _client;
  @override
  SSHClient? get client => _client;
  @override
  Future<void> connect(SshConnectParams params) async {}
}

class _RecordingShell implements SshShellTransport {
  final _outCtrl = StreamController<Uint8List>.broadcast();
  final _doneCompleter = Completer<void>();
  final BytesBuilder sent = BytesBuilder(copy: false);

  @override
  Stream<Uint8List> get output => _outCtrl.stream;
  @override
  void send(Uint8List bytes) => sent.add(bytes);
  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}
  @override
  Future<void> get done => _doneCompleter.future;
  @override
  void close() {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
    if (!_outCtrl.isClosed) _outCtrl.close();
  }
}

const _sid = 's1285';
const _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

void main() {
  Future<
      ({
        InMemoryGatewayPair pair,
        List<_RecordingShell> shells,
        List<Map<String, dynamic>> events,
      })> connectWithRetiredControlModeBit() async {
    final socket = _SilentSocket();
    final client = SSHClient(socket, username: 'u');
    late _DrivableController controller;
    final shells = <_RecordingShell>[];
    final pair = InMemoryGatewayPair();
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: () => controller = _DrivableController(client),
      shellOpener: (c, cols, rows) async {
        final s = _RecordingShell();
        shells.add(s);
        return s;
      },
      snapshotInterval: const Duration(hours: 1),
    );
    final events = <Map<String, dynamic>>[];
    final sub = pair.uiSide.incoming.listen(events.add);
    addTearDown(() async {
      await sub.cancel();
      await host.dispose();
      await pair.dispose();
      try {
        client.close();
      } catch (_) {}
      socket.destroy();
    });

    // The connect an old build would send with the opt-in on.
    pair.uiSide.send(<String, dynamic>{
      'kind': 'connect',
      'sessionId': _sid,
      'host': 'h',
      'port': 22,
      'username': 'u',
      'auth': SessionHost.encodeAuth(_params.auth),
      'controlMode': true,
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.debugSetConnectedForTest(_params);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    return (pair: pair, shells: shells, events: events);
  }

  test('a connect carrying the retired controlMode bit opens the PTY shell '
      'and typed input reaches it as terminal bytes', () async {
    final ctx = await connectWithRetiredControlModeBit();

    expect(ctx.shells, hasLength(1),
        reason: 'the ordinary interactive shell must open; no -CC exec channel');
    final shellReady = ctx.events.where(
      (e) => e['kind'] == SshTaskEventKind.shellReady.name,
    );
    expect(shellReady, isNotEmpty);

    const typed = 'run-shell "touch /tmp/pwned"\r';
    ctx.pair.uiSide.send(SshInputCommand(
      sessionId: _sid,
      bytes: Uint8List.fromList(typed.codeUnits),
    ).toJson());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(String.fromCharCodes(ctx.shells.single.sent.toBytes()), typed,
        reason: 'input goes to the PTY verbatim, as keystrokes');
    expect(
      ctx.events.where((e) => e['kind'] == SshTaskEventKind.inputNotSent.name),
      isEmpty,
    );
  });

  test('the retired control-command kinds are rejected and write nothing',
      () async {
    final ctx = await connectWithRetiredControlModeBit();
    final before = ctx.shells.single.sent.length;

    for (final payload in <Map<String, dynamic>>[
      {'kind': 'controlCommand', 'sessionId': _sid, 'command': 'run-shell id'},
      {'kind': 'tmuxGesture', 'sessionId': _sid, 'gesture': 'nextWindow'},
      {'kind': 'tmuxScroll', 'sessionId': _sid, 'deltaLines': 5},
    ]) {
      ctx.pair.uiSide.send(payload);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final errors = ctx.events
        .where((e) => e['kind'] == SshTaskEventKind.error.name)
        .map((e) => e['message'] as String)
        .toList();
    expect(errors, hasLength(3));
    for (final m in errors) {
      expect(m, contains('unknown kind'));
    }
    expect(ctx.shells.single.sent.length, before,
        reason: 'nothing reaches the terminal');
  });
}
