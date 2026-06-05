// SessionHost DA2 hyperlink-advertise wiring (#osc8-tmux-advertise).
//
// Verifies the host intercepts tmux's DA2 (Secondary Device Attributes) query
// in the live shell's output stream and:
//   1. ANSWERS it on the shell's stdin with the `tmux` reply (ESC[>84;0;0c) so
//      tmux advertises `hyperlinks` and forwards OSC-8 links to this client;
//   2. SWALLOWS the query so it is NOT forwarded to the UI terminal (the UI
//      terminal would otherwise emit its own `>0` reply, which tmux honors
//      FIRST, defeating the advertise).
//
// Reuses the #619 harness shape (silent socket + drivable controller + a
// recording shell transport whose output we can drive directly).

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/ssh/ssh_shell.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';

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
  _DrivableController(this._client);
  final SSHClient _client;
  @override
  SSHClient? get client => _client;
  @override
  Future<void> connect(SshConnectParams params) async {}
}

/// Shell transport with a driveable output stream + recorded stdin (`sent`).
class _DriveableShellTransport implements SshShellTransport {
  final _outCtrl = StreamController<Uint8List>.broadcast();
  final _doneCompleter = Completer<void>();
  final BytesBuilder sent = BytesBuilder(copy: false);
  bool closed = false;

  void emit(Uint8List bytes) => _outCtrl.add(bytes);

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
    closed = true;
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
    if (!_outCtrl.isClosed) _outCtrl.close();
  }
}

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);
String _s(List<int> b) => String.fromCharCodes(b);

void main() {
  Future<
      ({
        SessionHost host,
        SshSessionProxy proxy,
        InMemoryGatewayPair pair,
        List<_DriveableShellTransport> opened,
        StringBuffer forwarded,
      })> setUpConnectedShell(String sid) async {
    final socket = _SilentSocket();
    final sentinelClient = SSHClient(socket, username: 'u');
    addTearDown(() {
      try {
        sentinelClient.close();
      } catch (_) {}
      socket.destroy();
    });

    late _DrivableController controller;
    _DrivableController factory() {
      controller = _DrivableController(sentinelClient);
      return controller;
    }

    final opened = <_DriveableShellTransport>[];
    Future<SshShellTransport?> opener(SSHClient c, int cols, int rows) async {
      final t = _DriveableShellTransport();
      opened.add(t);
      return t;
    }

    final pair = InMemoryGatewayPair();
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: factory,
      shellOpener: opener,
      snapshotInterval: const Duration(hours: 1),
    );
    final proxy = SshSessionProxy(sessionId: sid, gateway: pair.uiSide);

    // The forwarded terminal byte stream the UI would render.
    final forwarded = StringBuffer();
    proxy.output.listen((bytes) => forwarded.write(_s(bytes)));

    proxy.connect(const SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.debugSetConnectedForTest(const SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    ));
    // Let the shell open + output listener wire up.
    await Future<void>.delayed(const Duration(milliseconds: 60));

    addTearDown(() async {
      await proxy.dispose();
      await host.dispose();
      await pair.dispose();
    });
    return (
      host: host,
      proxy: proxy,
      pair: pair,
      opened: opened,
      forwarded: forwarded,
    );
  }

  test('answers tmux DA2 query on stdin and swallows it from UI output',
      () async {
    final ctx = await setUpConnectedShell('da2:22:u:1');
    expect(ctx.opened, hasLength(1), reason: 'one shell opened');
    final shell = ctx.opened.first;

    // Remote (tmux) sends some output, the DA2 query, then more output.
    shell.emit(_b('prompt\$ \x1b[>cmore'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 1) We replied as tmux on the shell's stdin.
    expect(_s(shell.sent.toBytes()), '\x1b[>84;0;0c',
        reason: 'host must answer DA2 with the tmux (T=84) reply');

    // 2) The query must NOT appear in the bytes forwarded to the UI terminal.
    final forwarded = ctx.forwarded.toString();
    expect(forwarded.contains('\x1b[>c'), isFalse,
        reason: 'DA2 query must be swallowed, not forwarded to the terminal');
    // 3) The surrounding bytes still reach the UI.
    expect(forwarded.contains('prompt\$ '), isTrue);
    expect(forwarded.contains('more'), isTrue);
  });

  test('non-tmux output is forwarded verbatim with no DA2 reply', () async {
    final ctx = await setUpConnectedShell('plain:22:u:1');
    final shell = ctx.opened.first;

    shell.emit(_b('\x1b[32mhello\x1b[0m\r\n'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(shell.sent.length, 0, reason: 'no DA2 query => no reply');
    expect(ctx.forwarded.toString().contains('\x1b[32mhello\x1b[0m\r\n'),
        isTrue);
  });

  test('DA2 query split across two output chunks is still answered', () async {
    final ctx = await setUpConnectedShell('split:22:u:1');
    final shell = ctx.opened.first;

    shell.emit(_b('x\x1b[>'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    shell.emit(_b('cy'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(_s(shell.sent.toBytes()), '\x1b[>84;0;0c');
    final forwarded = ctx.forwarded.toString();
    expect(forwarded.contains('\x1b[>c'), isFalse);
    expect(forwarded.contains('x'), isTrue);
    expect(forwarded.contains('y'), isTrue);
  });
}
