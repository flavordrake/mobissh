// #619 — the run-on-connect initial command must gate on SHELL-READY, not the
// bare `connected` state transition.
//
// The race: the UI `InitialCommandRunner` fires the command via
// `proxy.sendInput` on the `connected` transition, but the task-side PTY shell
// is opened ASYNCHRONOUSLY (`_ensureShell`) after `connected`. On a slow host
// the shell isn't wired yet when the command bytes arrive, so `_handleInput`
// drops them into scrollback instead of the live shell — the command is lost.
//
// This test reproduces the race deterministically with a fake `HostShellOpener`
// whose open is DELAYED relative to `connected`. We assert the initial command
// bytes reach the LIVE shell (its `send`), not scrollback, and only AFTER the
// shell is ready. RED on the old `connected`-gated runner (sent too early →
// dropped); GREEN once the runner gates on the task-side shell-ready signal.

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
import 'package:mobissh/state/sessions.dart';

/// Silent socket → lets us build a real [SSHClient] so `controller.client` is
/// non-null without any network IO or pending timers.
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

  // Suppress the real socket connect: we drive `connected` /
  // disconnect transitions explicitly via [debugSetConnectedForTest] and
  // [disconnect]. Without this, the production `connect` opens a real socket
  // that fails DNS lookup and transitions the session to `failed`, which would
  // drop the (deliberately delayed) shell before it opens.
  @override
  Future<void> connect(SshConnectParams params) async {}
}

/// Fake PTY transport that records the bytes the host's `_handleInput` wrote to
/// the LIVE shell (`send`). If the initial command races ahead of shell-open,
/// `_handleInput` routes it to scrollback instead and `sent` stays empty.
class _RecordingShellTransport implements SshShellTransport {
  final _outCtrl = StreamController<Uint8List>.broadcast();
  final _doneCompleter = Completer<void>();
  final BytesBuilder sent = BytesBuilder(copy: false);
  bool closed = false;

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

void main() {
  test(
    'initial command reaches the live shell when shell-open is DELAYED (#619)',
    () async {
      const sid = 'slow:22:u:1';

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

      // The crux: the shell opens with a DELAY after `connected`. A naive
      // runner that fires on `connected` would send the command during this
      // window, before the shell exists → dropped to scrollback.
      final opened = <_RecordingShellTransport>[];
      Future<SshShellTransport?> opener(SSHClient c, int cols, int rows) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        final t = _RecordingShellTransport();
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
      final runner = InitialCommandRunner();
      addTearDown(() async {
        runner.dispose();
        await proxy.dispose();
        await host.dispose();
        await pair.dispose();
      });

      // Arm BEFORE connect (matches _connectWithParams ordering).
      runner.arm(sessionId: sid, proxy: proxy, command: 'tmux a');

      proxy.connect(
        const SshConnectParams(
          host: 'slow',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Drive `connected` — the shell open is still pending (80ms delay).
      controller.debugSetConnectedForTest(
        const SshConnectParams(
          host: 'slow',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );

      // Let the `connected` event propagate to the UI. A runner that fires on
      // bare `connected` sends the command NOW — before the shell exists.
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Now let the delayed shell finish opening + the shell-ready signal flow.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(opened.length, 1, reason: 'one shell should have opened');
      final shellBytes = String.fromCharCodes(opened.first.sent.toBytes());
      expect(
        shellBytes,
        'tmux a\n',
        reason:
            'initial command must reach the LIVE shell after shell-ready; '
            'if it raced ahead of shell-open it was dropped to scrollback',
      );
      expect(runner.hasFired(sid), isTrue);
    },
  );

  test('initial command does NOT re-fire when the shell re-opens on reconnect '
      '(#619/#551)', () async {
    const sid = 'h:22:u:1';

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

    final opened = <_RecordingShellTransport>[];
    Future<SshShellTransport?> opener(SSHClient c, int cols, int rows) async {
      final t = _RecordingShellTransport();
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
    final runner = InitialCommandRunner();
    addTearDown(() async {
      runner.dispose();
      await proxy.dispose();
      await host.dispose();
      await pair.dispose();
    });

    runner.arm(sessionId: sid, proxy: proxy, command: 'echo hi');

    proxy.connect(
      const SshConnectParams(
        host: 'h',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 40));

    controller.debugSetConnectedForTest(
      const SshConnectParams(
        host: 'h',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ),
    );
    await settle();
    expect(
      String.fromCharCodes(opened.first.sent.toBytes()),
      'echo hi\n',
      reason: 'fired once on the first shell-ready',
    );

    // Reconnect: drop, then re-enter connected → the host re-opens a fresh
    // shell and re-emits shell-ready. The runner is one-shot; it must NOT
    // re-send the command into the new shell.
    await controller.disconnect();
    await settle();
    controller.debugSetConnectedForTest(
      const SshConnectParams(
        host: 'h',
        port: 22,
        username: 'u',
        auth: SshAuth.password('p'),
      ),
    );
    await settle();

    expect(opened.length, 2, reason: 'reconnect re-opened a fresh shell');
    expect(
      opened.last.sent.length,
      0,
      reason: 'initial command must NOT re-run into the reconnect shell',
    );
  });
}
