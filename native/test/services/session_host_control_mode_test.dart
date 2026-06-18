// SessionHost tmux control-mode (`-CC`) RENDER + RESIZE wiring — Part B (#909).
//
// Verifies the FLAG-ON behaviour of the host:
//   1. On shell open it ENTERS control mode (`tmux -CC …` written to stdin).
//   2. `%output` for the active window is PARSED, demuxed, and forwarded to the
//      UI as plain terminal bytes (the grid renders).
//   3. A PTY resize becomes a `refresh-client -C cols,rows` command line — the
//      SINGLE resize primitive — NOT a PTY winsize resize.
//   4. The FINAL settled resize size is delivered (never dropped).
// And the FLAG-OFF default is provably UNCHANGED (no tmux -CC entry; resize is a
// PTY winsize resize; raw bytes forwarded verbatim).
//
// Reuses the #osc8 / #619 host harness shape (silent socket + drivable
// controller + recording shell transport).

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
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';

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

/// Shell transport recording BOTH stdin writes (`sent`) and resize calls.
class _DriveableShellTransport implements SshShellTransport {
  final _outCtrl = StreamController<Uint8List>.broadcast();
  final _doneCompleter = Completer<void>();
  final BytesBuilder sent = BytesBuilder(copy: false);
  final List<(int, int)> resizes = <(int, int)>[];

  void emit(Uint8List bytes) => _outCtrl.add(bytes);

  @override
  Stream<Uint8List> get output => _outCtrl.stream;
  @override
  void send(Uint8List bytes) => sent.add(bytes);
  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) =>
      resizes.add((cols, rows));
  @override
  Future<void> get done => _doneCompleter.future;
  @override
  void close() {
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

  group('flag ON — control mode', () {
    late bool prev;
    setUp(() => prev = setTmuxControlModeForTest(true));
    tearDown(() => setTmuxControlModeForTest(prev));

    test('enters control mode by writing tmux -CC to the shell stdin', () async {
      final ctx = await setUpConnectedShell('cc:22:u:1');
      expect(ctx.opened, hasLength(1));
      expect(_s(ctx.opened.first.sent.toBytes()), startsWith('tmux -CC'));
    });

    test('%output renders demuxed bytes to the UI (the grid)', () async {
      final ctx = await setUpConnectedShell('cc:22:u:2');
      final shell = ctx.opened.first;
      shell.emit(_b('%output %0 hello\\040grid\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ctx.forwarded.toString(), contains('hello grid'));
      // The raw control framing is NOT forwarded verbatim.
      expect(ctx.forwarded.toString().contains('%output'), isFalse);
    });

    test('resize becomes refresh-client -C, NOT a PTY winsize resize', () async {
      final ctx = await setUpConnectedShell('cc:22:u:3');
      final shell = ctx.opened.first;
      shell.sent.clear(); // drop the entry command
      ctx.proxy.sendResize(100, 30);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_s(shell.sent.toBytes()), contains('refresh-client -C 100,30'));
      expect(shell.resizes, isEmpty,
          reason: 'control mode must not winsize-resize the -CC PTY');
    });

    test('FINAL settled resize is delivered — never dropped (#903/#905)', () async {
      final ctx = await setUpConnectedShell('cc:22:u:4');
      final shell = ctx.opened.first;
      shell.sent.clear();
      // The UI coalescer emits only the FINAL settled size; the host must send it.
      ctx.proxy.sendResize(88, 27);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_s(shell.sent.toBytes()), contains('refresh-client -C 88,27'));
    });
  });

  group('flag OFF — scrape path unchanged (shipped default)', () {
    test('does NOT enter control mode; raw bytes forwarded verbatim', () async {
      final ctx = await setUpConnectedShell('plain:22:u:1');
      final shell = ctx.opened.first;
      // No tmux -CC entry written.
      expect(shell.sent.length, 0);
      shell.emit(_b('\x1b[32mhello\x1b[0m\r\n'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ctx.forwarded.toString(), contains('\x1b[32mhello\x1b[0m\r\n'));
    });

    test('resize is a PTY winsize resize (not refresh-client -C)', () async {
      final ctx = await setUpConnectedShell('plain:22:u:2');
      final shell = ctx.opened.first;
      ctx.proxy.sendResize(120, 40);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(shell.resizes, contains((120, 40)));
      expect(_s(shell.sent.toBytes()).contains('refresh-client'), isFalse);
    });
  });
}
