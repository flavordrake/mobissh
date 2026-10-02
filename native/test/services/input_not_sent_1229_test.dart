// #1229 item 1 (security): input that reaches the task while no shell is open
// must be DROPPED and reported to the UI, never written into the scrollback.
// The scrollback reseeds the terminal on resume and ships in snapshots, so a
// password typed in that window used to be kept and redrawn in cleartext.
//
// #1252 item 1 rides the same harness: the task-side connect log must not
// carry the password length.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/connect_trace.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/ssh/ssh_shell.dart';

/// Silent socket: a real [SSHClient] with no network IO, so
/// `controller.client` is non-null and `_ensureShell` runs the opener.
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

class _RecordingShellTransport implements SshShellTransport {
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

const _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('hunter2-secret'),
);

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  late _SilentSocket socket;
  late SSHClient client;
  late _DrivableController controller;
  late InMemoryGatewayPair pair;
  late SessionHost host;
  late SshSessionProxy proxy;
  // Whether the next shell open succeeds; null-shell is the bug's window.
  late bool shellAvailable;
  late List<_RecordingShellTransport> opened;

  setUp(() {
    socket = _SilentSocket();
    client = SSHClient(socket, username: 'u');
    shellAvailable = false;
    opened = [];
    pair = InMemoryGatewayPair();
    host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: () => controller = _DrivableController(client),
      shellOpener: (c, cols, rows) async {
        if (!shellAvailable) return null;
        final t = _RecordingShellTransport();
        opened.add(t);
        return t;
      },
      snapshotInterval: const Duration(hours: 1),
    );
    proxy = SshSessionProxy(sessionId: 'h:22:u:1', gateway: pair.uiSide);
  });

  tearDown(() async {
    await proxy.dispose();
    await host.dispose();
    await pair.dispose();
    try {
      client.close();
    } catch (_) {}
    socket.destroy();
  });

  test('input with no shell never reaches scrollback and is reported to the '
      'UI (#1229)', () async {
    proxy.connect(_params);
    await _settle();
    controller.debugSetConnectedForTest(_params);
    await _settle();
    expect(proxy.data.inputNotSent, isFalse);

    proxy.sendInput(Uint8List.fromList(utf8.encode('TypedPassw0rd\r')));
    await _settle();

    // Ask for an on-demand snapshot: it carries the scrollback tail.
    proxy.rebind();
    await _settle();
    expect(proxy.snapshot.scrollbackTail, isNot(contains('TypedPassw0rd')));
    expect(
      proxy.data.inputNotSent,
      isTrue,
      reason: 'the UI must learn the input was not sent',
    );
  });

  test('the not-sent signal clears once a shell is open again', () async {
    proxy.connect(_params);
    await _settle();
    controller.debugSetConnectedForTest(_params);
    await _settle();
    proxy.sendInput(Uint8List.fromList(utf8.encode('x')));
    await _settle();
    expect(proxy.data.inputNotSent, isTrue);

    shellAvailable = true;
    await controller.disconnect();
    await _settle();
    controller.debugSetConnectedForTest(_params);
    await _settle();
    expect(opened, hasLength(1));
    expect(proxy.data.inputNotSent, isFalse);

    proxy.sendInput(Uint8List.fromList(utf8.encode('ok')));
    await _settle();
    expect(String.fromCharCodes(opened.single.sent.toBytes()), 'ok');
  });

  test('the connect log names the auth method but not the password length '
      '(#1252)', () async {
    proxy.connect(_params);
    await _settle();
    final log = connectLogSnapshot().join('\n');
    expect(log, contains('decodeAuth password'));
    expect(log, isNot(contains('pwLen')));
    expect(log, isNot(contains('hunter2-secret')));
  });
}
