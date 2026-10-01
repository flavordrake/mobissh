// #1211 — deep link `tmux=<session>&window=<name>` selects the tmux window.
//
// The selection runs as a SEPARATE non-PTY exec channel on the session's own
// SSH connection (`tmux select-window -t '=S:=W'`), never as keystrokes into
// the user's terminal (codex finding 7 on #1117): these tests drive the real
// SessionHost ↔ SshSessionProxy wiring over an in-memory gateway with a fake
// PTY transport that records every byte the terminal would have received, and
// a fake exec runner that records every exec line.
//
//   * the IPC envelopes round-trip;
//   * the proxy's select reaches the exec runner with the exact line and
//     writes ZERO bytes to the PTY; exit 0 → selected, non-zero → not;
//   * the fresh-connect ordering: armed attach + onSent select fire only on
//     shell-ready, the attach line lands in the PTY FIRST, the select goes
//     over exec AFTER it, and the PTY never sees `select-window`;
//   * the runner's "attached to <session>" record survives the tick that set
//     it and is dropped by the next shell-ready (a reconnect's fresh shell is
//     no longer inside tmux).

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/link_verb.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/ssh/ssh_shell.dart';
import 'package:mobissh/state/sessions.dart';

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
  _RecordingShellTransport(this.events);
  final List<String> events;
  final _outCtrl = StreamController<Uint8List>.broadcast();
  final _doneCompleter = Completer<void>();
  final BytesBuilder sent = BytesBuilder(copy: false);

  @override
  Stream<Uint8List> get output => _outCtrl.stream;

  @override
  void send(Uint8List bytes) {
    sent.add(bytes);
    events.add('pty:${String.fromCharCodes(bytes)}');
  }

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
  auth: SshAuth.password('p'),
);

class _Rig {
  _Rig._(this.host, this.proxy, this.pair, this.opened, this.events,
      this.execLines);

  final SessionHost host;
  final SshSessionProxy proxy;
  final InMemoryGatewayPair pair;
  final List<_RecordingShellTransport> opened;
  final List<String> events;
  final List<String> execLines;
  late _DrivableController controller;

  String get ptyBytes => opened.isEmpty
      ? ''
      : String.fromCharCodes(opened.first.sent.toBytes());

  static _Rig build(String sid, {required int execExit}) {
    final socket = _SilentSocket();
    final client = SSHClient(socket, username: 'u');
    addTearDown(() {
      try {
        client.close();
      } catch (_) {}
      socket.destroy();
    });
    final opened = <_RecordingShellTransport>[];
    final events = <String>[];
    final execLines = <String>[];
    late _Rig rig;
    final pair = InMemoryGatewayPair();
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: () => rig.controller = _DrivableController(client),
      shellOpener: (c, cols, rows) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final t = _RecordingShellTransport(events);
        opened.add(t);
        return t;
      },
      execRunner: (c, line) async {
        execLines.add(line);
        events.add('exec:$line');
        return execExit;
      },
      snapshotInterval: const Duration(hours: 1),
    );
    final proxy = SshSessionProxy(sessionId: sid, gateway: pair.uiSide);
    rig = _Rig._(host, proxy, pair, opened, events, execLines);
    addTearDown(() async {
      await proxy.dispose();
      await host.dispose();
      await pair.dispose();
    });
    return rig;
  }

  Future<void> connect() async {
    proxy.connect(_params);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.debugSetConnectedForTest(_params);
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
}

void main() {
  group('IPC envelopes', () {
    test('SshTmuxSelectWindowCommand round-trips', () {
      const cmd = SshTmuxSelectWindowCommand(
        sessionId: 'h:22:u:1',
        requestId: 'win-1',
        session: 'main',
        window: 'beta',
      );
      final restored =
          SshTaskCommand.fromJson(cmd.toJson()) as SshTmuxSelectWindowCommand;
      expect(restored.kind, SshTaskCommandKind.tmuxSelectWindow);
      expect(restored.sessionId, 'h:22:u:1');
      expect(restored.requestId, 'win-1');
      expect(restored.session, 'main');
      expect(restored.window, 'beta');
    });

    test('TmuxSelectWindowResultEvent round-trips both outcomes', () {
      for (final selected in [true, false]) {
        final ev = TmuxSelectWindowResultEvent(
          sessionId: 'h:22:u:1',
          requestId: 'win-1',
          selected: selected,
        );
        final restored = SshTaskEvent.fromJson(ev.toJson())
            as TmuxSelectWindowResultEvent;
        expect(restored.kind, SshTaskEventKind.tmuxSelectWindowResult);
        expect(restored.requestId, 'win-1');
        expect(restored.selected, selected);
      }
    });
  });

  group('selection runs over exec, never the PTY', () {
    test('match: exact exec line, selected=true, zero PTY bytes', () async {
      final rig = _Rig.build('h:22:u:1', execExit: 0);
      await rig.connect();
      expect(rig.opened, hasLength(1));

      final ok = await rig.proxy.tmuxSelectWindow(
          session: 'main', window: 'beta');

      expect(ok, isTrue);
      expect(rig.execLines, ["tmux select-window -t '=main:=beta'"]);
      expect(rig.ptyBytes, isEmpty,
          reason: 'the selection must never be typed into the terminal');
    });

    test('no match (non-zero exit): selected=false, nothing typed', () async {
      final rig = _Rig.build('h:22:u:2', execExit: 1);
      await rig.connect();
      final ok = await rig.proxy.tmuxSelectWindow(
          session: 'main', window: 'nope');
      expect(ok, isFalse);
      expect(rig.execLines, hasLength(1));
      expect(rig.ptyBytes, isEmpty);
    });

    test('an invalid token never reaches exec (host re-validates)', () async {
      final rig = _Rig.build('h:22:u:3', execExit: 0);
      await rig.connect();
      rig.pair.uiSide.send(const SshTmuxSelectWindowCommand(
        sessionId: 'h:22:u:3',
        requestId: 'forged',
        session: 'main',
        window: "x';reboot;'",
      ).toJson());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rig.execLines, isEmpty);
      expect(rig.ptyBytes, isEmpty);
    });
  });

  group('fresh connect ordering', () {
    test('attach on shell-ready, THEN select over exec; PTY sees only the '
        'attach line', () async {
      const sid = 'h:22:u:4';
      final rig = _Rig.build(sid, execExit: 0);
      final runner = InitialCommandRunner();
      addTearDown(runner.dispose);
      final verb = TmuxAttach('main', window: 'beta');

      runner.arm(
        sessionId: sid,
        proxy: rig.proxy,
        command: verb.commandLine,
        onSent: () {
          rig.events.add('onSent');
          runner.markTmuxAttached(sid, verb.name, rig.proxy);
          unawaited(rig.proxy.tmuxSelectWindow(
              session: verb.name, window: verb.window!));
        },
      );

      rig.proxy.connect(_params);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      rig.controller.debugSetConnectedForTest(_params);
      // `connected` has propagated but the shell (40ms) is not open yet:
      // nothing may have been attached or selected.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(rig.execLines, isEmpty,
          reason: 'select must wait for the attach (shell-ready)');
      expect(rig.events, isNot(contains('onSent')));

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(rig.ptyBytes, 'tmux new-session -A -s main\n');
      expect(rig.execLines, ["tmux select-window -t '=main:=beta'"]);
      final ptyAt = rig.events.indexOf('pty:tmux new-session -A -s main\n');
      final execAt =
          rig.events.indexOf("exec:tmux select-window -t '=main:=beta'");
      expect(ptyAt, greaterThanOrEqualTo(0));
      expect(execAt, greaterThan(ptyAt), reason: 'select AFTER the attach');
      expect(rig.ptyBytes, isNot(contains('select-window')));
      expect(runner.sendNowCount(sid), 0);
      expect(runner.tmuxAttachedTo(sid), 'main',
          reason: 'the record survives the shell-ready tick that set it');
    });

    test('a later shell-ready (reconnect → fresh shell) drops the attached '
        'record', () async {
      const sid = 'h:22:u:5';
      final rig = _Rig.build(sid, execExit: 0);
      final runner = InitialCommandRunner();
      addTearDown(runner.dispose);
      runner.arm(
        sessionId: sid,
        proxy: rig.proxy,
        command: 'tmux new-session -A -s main',
        onSent: () => runner.markTmuxAttached(sid, 'main', rig.proxy),
      );
      await rig.connect();
      expect(runner.tmuxAttachedTo(sid), 'main');

      rig.pair.taskSide.send(const SshShellReadyEvent(sessionId: sid).toJson());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(runner.tmuxAttachedTo(sid), isNull);
    });

    test('sendNow of a TmuxAttach records the attachment', () async {
      const sid = 'h:22:u:6';
      final rig = _Rig.build(sid, execExit: 0);
      await rig.connect();
      final runner = InitialCommandRunner();
      addTearDown(runner.dispose);
      runner.sendNow(
          sessionId: sid, proxy: rig.proxy, command: TmuxAttach('work'));
      expect(runner.tmuxAttachedTo(sid), 'work');
    });
  });
}
