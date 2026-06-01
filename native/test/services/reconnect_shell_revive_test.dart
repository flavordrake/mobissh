// #590 — auto-reconnect must re-open a LIVE shell (byte-flow restored).
//
// State-transition regression: after the SSH transport drops and the controller
// auto-reconnects (reconnecting/softDisconnected → connected), the task-side
// host previously reused the prior connection's (dead) PTY shell handle. The
// `_HostedSession.shell` guard in `_ensureShell` made the second `connected`
// a no-op, so ZERO bytes flowed while the UI showed `connected` — a live-looking
// but frozen terminal.
//
// This is the byte-flow gate the fast gate was missing for the reconnect path.
// It runs HEADLESS via InMemoryGatewayPair + a fake `HostShellOpener` that
// hands out a FRESH transport per open (each emitting a prompt byte). The bug =
// the SECOND byte-flow assertion fails because no new shell was opened on
// reconnect.

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

/// A socket that never emits and never errors — lets us construct a real
/// [SSHClient] so `controller.client` is non-null (the gate `_ensureShell`
/// checks) WITHOUT any network IO or pending timers.
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

/// Controller that exposes a non-null [client] sentinel so the host's shell
/// opener seam is reached, and lets the test drive `connected` /
/// transport-drop transitions deterministically (no real socket auth).
class _DrivableController extends SshSessionController {
  _DrivableController(this._client);

  final SSHClient _client;

  @override
  SSHClient? get client => _client;
}

/// A fake PTY transport. Each instance emits a one-byte "prompt" on open so a
/// listener can prove bytes flowed for THIS connection. `done` can be completed
/// to simulate the channel closing on transport drop.
class _FakeShellTransport implements SshShellTransport {
  _FakeShellTransport(this.tag);

  final String tag;
  final _outCtrl = StreamController<Uint8List>.broadcast();
  final _doneCompleter = Completer<void>();
  bool closed = false;

  void emitPrompt() {
    if (!_outCtrl.isClosed) {
      _outCtrl.add(Uint8List.fromList('$tag\$ '.codeUnits));
    }
  }

  @override
  Stream<Uint8List> get output => _outCtrl.stream;

  @override
  void send(Uint8List bytes) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  Future<void> get done => _doneCompleter.future;

  void completeDone() {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }

  @override
  void close() {
    closed = true;
    completeDone();
    if (!_outCtrl.isClosed) _outCtrl.close();
  }
}

void main() {
  test(
    'auto-reconnect re-opens a LIVE shell — bytes flow every cycle (#590)',
    () async {
      const sid = 'h:22:u:1';

      // Construct one real SSHClient over a silent socket so `client` is
      // non-null. We never authenticate; the host only reads `client` to decide
      // a shell can be opened, and the fake opener ignores the value.
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

      // Hand out a fresh transport per open. A new live connection => a new
      // shell => a new prompt byte. If the host reuses the dead handle, the
      // opener is NOT called a second time and no second transport exists.
      final opened = <_FakeShellTransport>[];
      Future<SshShellTransport?> opener(SSHClient c, int cols, int rows) async {
        final t = _FakeShellTransport('s${opened.length}');
        opened.add(t);
        // Emit the prompt on the next microtask so the host's listen() is wired.
        scheduleMicrotask(t.emitPrompt);
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
      addTearDown(() async {
        await proxy.dispose();
        await host.dispose();
        await pair.dispose();
      });

      // Capture everything the task side streams to the UI terminal.
      final out = <int>[];
      final sub = proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);

      // Kick off connect so the host hosts the session + wires its state
      // listener. The real auth never completes (silent socket), so we drive
      // `connected` ourselves via the controller.
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
          Future<void>.delayed(const Duration(milliseconds: 30));

      // --- Cycle 1: first connect → live shell ---
      controller.debugSetConnectedForTest(
        const SshConnectParams(
          host: 'h',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      await settle();

      expect(opened.length, 1, reason: 'first connect should open one shell');
      expect(
        out.isNotEmpty,
        isTrue,
        reason: 'first connect produced no shell bytes',
      );

      // --- Transport drops → session leaves `connected` ---
      // Emit a non-connected transition (the auto-reconnect path passes through
      // reconnecting/softDisconnected/idle on its way back to connected). The
      // host must DROP the prior shell here.
      //
      // CRITICAL to reproduce the RACE: do NOT complete the old transport's
      // `done` before the reconnect. On a real socket drop the controller can
      // re-reach `connected` BEFORE the dead PTY channel's `done` microtask
      // runs — so the stale `hosted.shell` is still non-null when the second
      // `connected` fires. Relying on `transport.done` to clear it (the old
      // behavior) loses this race; the fix clears synchronously on the
      // non-connected transition. We complete the old `done` only AFTER the
      // reconnect, mimicking the lagging channel-close.
      await controller.disconnect();
      await settle();

      final beforeReconnect = out.length;

      // --- Cycle 2: reconnect re-enters connected ---
      controller.debugSetConnectedForTest(
        const SshConnectParams(
          host: 'h',
          port: 22,
          username: 'u',
          auth: SshAuth.password('p'),
        ),
      );
      await settle();

      // The lagging channel-close from the dropped connection arrives LATE,
      // after the reconnect already re-entered connected. With the old
      // transport.done-clears-shell behavior this would null out the freshly
      // opened shell; the fix's generation guard ignores this stale `done`.
      opened.first.completeDone();
      await settle();

      // THE BUG: with the stale-shell reuse, the opener is never called a
      // second time and no new bytes arrive while state == connected.
      expect(
        opened.length,
        2,
        reason:
            'reconnect did NOT open a fresh shell — reused the dead handle (#590)',
      );
      // The live (second) shell must still be attached after the stale `done`.
      expect(
        opened.last.closed,
        isFalse,
        reason: 'the reconnect shell was torn down by a stale channel-close',
      );
      expect(
        out.length,
        greaterThan(beforeReconnect),
        reason:
            'reconnect reached `connected` but ZERO new shell bytes flowed — '
            'the dead-shell hang (#590)',
      );
    },
  );
}
