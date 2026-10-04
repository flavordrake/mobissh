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
//
// #1269 — HERMETIC. The controller's `connect` is inert: the previous version
// let the real `connect('h':22)` run, whose DNS failure ("Failed host lookup:
// 'h'") emitted `failed` at an arbitrary point. Under load it landed AFTER the
// test's second `connected`, so the host's `_dropShell` closed the reconnect
// shell and the test reported "torn down by a stale channel-close" — a test
// artifact, not the stale-`done` race. Every wait is a bounded poll on the
// specific state or byte, never a fixed delay.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/ssh/ssh_shell.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';

const _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

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
  Future<void> flush() async {}

  @override
  void destroy() {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }
}

/// Controller that exposes a non-null [client] sentinel so the host's shell
/// opener seam is reached, and lets the test drive `connected` /
/// transport-drop transitions deterministically. [connect] is INERT (#1269):
/// no socket, no DNS, no timers — the test is the only source of state.
class _DrivableController extends SshSessionController {
  _DrivableController(this._client);

  final SSHClient _client;

  /// Completes when the host has called [connect] — its state listener is
  /// wired before that call, so driving states after this is safe.
  final connectCalled = Completer<void>();

  @override
  SSHClient? get client => _client;

  @override
  Future<void> connect(SshConnectParams params) async {
    if (!connectCalled.isCompleted) connectCalled.complete();
  }
}

/// A fake PTY transport. Each instance emits a "prompt" on open so a listener
/// can prove bytes flowed for THIS connection. Like a real dartssh2 channel,
/// `close()` does NOT complete `done` — the channel-close lands later, when
/// the test calls [completeDone] (the lagging close of a dropped connection).
class _FakeShellTransport implements SshShellTransport {
  _FakeShellTransport(this.tag) {
    // Emit the prompt once the host LISTENS. Scheduling it from the opener
    // (the pre-#1269 version) fired before `listen()` on this broadcast
    // stream, so the prompt was silently dropped and `out` held only status
    // text — the byte-flow assertion never saw shell bytes.
    _outCtrl = StreamController<Uint8List>.broadcast(
      onListen: () => scheduleMicrotask(emitPrompt),
    );
  }

  final String tag;
  late final StreamController<Uint8List> _outCtrl;
  final _doneCompleter = Completer<void>();
  bool closed = false;

  void emit(String text) {
    if (!_outCtrl.isClosed) {
      _outCtrl.add(Uint8List.fromList(text.codeUnits));
    }
  }

  void emitPrompt() => emit('$tag\$ ');

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
    if (!_outCtrl.isClosed) _outCtrl.close();
  }
}

/// Bounded poll for [cond] (#1178 rule: never a fixed sleep). Yields to the
/// event loop between checks so gateway/microtask work can land.
Future<void> _pollUntil(
  bool Function() cond,
  String what, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) {
      fail('timed out after ${timeout.inMilliseconds}ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// One hosted session wired UI-side ↔ task-side over [InMemoryGatewayPair].
class _Harness {
  _DrivableController? _built;
  _DrivableController get controller => _built!;
  final opened = <_FakeShellTransport>[];

  /// Per-open gates: when present at index i, the i-th open does not return
  /// its transport until the gate completes (holds an open "in flight").
  final openGates = <int, Completer<void>>{};
  final out = StringBuffer();

  Future<void> start() async {
    final socket = _SilentSocket();
    // A real SSHClient over a silent socket so `client` is non-null. Never
    // authenticated; the fake opener ignores it.
    final sentinelClient = SSHClient(socket, username: 'u');
    addTearDown(() {
      try {
        sentinelClient.close();
      } catch (_) {}
      socket.destroy();
    });

    _DrivableController factory() =>
        _built = _DrivableController(sentinelClient);

    // A fresh transport per open. A new live connection => a new shell => a
    // new prompt. If the host reuses the dead handle, the opener is NOT called
    // a second time and no second transport exists.
    Future<SshShellTransport?> opener(SSHClient c, int cols, int rows) async {
      final index = opened.length;
      final t = _FakeShellTransport('s$index');
      opened.add(t);
      final gate = openGates[index];
      if (gate != null) await gate.future;
      return t;
    }

    final pair = InMemoryGatewayPair();
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: factory,
      shellOpener: opener,
      snapshotInterval: const Duration(hours: 1),
    );
    final proxy = SshSessionProxy(sessionId: 'h:22:u:1', gateway: pair.uiSide);
    addTearDown(() async {
      await proxy.dispose();
      await host.dispose();
      await pair.dispose();
    });

    final sub = proxy.output.listen((b) => out.write(latin1.decode(b)));
    addTearDown(sub.cancel);

    unawaited(proxy.connect(_params));
    await _pollUntil(() => _built != null, 'host built the controller');
    await controller.connectCalled.future
        .timeout(const Duration(seconds: 5));
  }

  bool saw(String text) => out.toString().contains(text);

  /// First connect → shell s0 attached and streaming.
  Future<void> connectFirst() async {
    controller.debugSetConnectedForTest(_params);
    await _pollUntil(() => saw(r's0$ '), 'first shell prompt s0');
    expect(opened.length, 1, reason: 'first connect should open one shell');
  }

  /// Transport drops → session leaves `connected`. The old shell's `done` is
  /// deliberately NOT completed: on a real drop the dead channel's close lags.
  Future<void> drop() async {
    await controller.disconnect();
    await _pollUntil(
      () => opened.first.closed,
      'host dropped the old shell on leaving connected',
    );
    expect(
      opened.first.closed,
      isTrue,
      reason: 'leaving connected must close the old shell synchronously',
    );
  }

  /// The reconnect shell must be attached AND still streaming: bytes emitted
  /// AFTER the stale `done` reach the UI (a nulled shell would have cancelled
  /// its output subscription).
  Future<void> expectLiveReconnectShell() async {
    expect(
      opened.length,
      2,
      reason:
          'reconnect did NOT open a fresh shell — reused the dead handle (#590)',
    );
    expect(
      opened.last.closed,
      isFalse,
      reason: 'the reconnect shell was torn down by a stale channel-close',
    );
    opened.last.emit('after-stale-done');
    await _pollUntil(
      () => saw('after-stale-done'),
      'reconnect shell still streams after the stale done (#590)',
    );
  }
}

void main() {
  test(
    'auto-reconnect re-opens a LIVE shell — bytes flow every cycle (#590)',
    () async {
      final h = _Harness();
      await h.start();
      await h.connectFirst();
      await h.drop();

      // Cycle 2: reconnect re-enters connected → a fresh shell s1 streams.
      h.controller.debugSetConnectedForTest(_params);
      await _pollUntil(() => h.saw(r's1$ '), 'reconnect shell prompt s1');

      // The lagging channel-close of the dropped connection arrives AFTER the
      // reconnect shell is attached. The generation guard must ignore it.
      h.opened.first.completeDone();
      await h.opened.first.done;
      await h.expectLiveReconnectShell();
    },
  );

  test(
    'stale done lands after connected re-entered but BEFORE the reconnect '
    'shell opens — ignored (#1269)',
    () async {
      final h = _Harness();
      // Hold the SECOND open in flight: connected is re-entered, the opener is
      // called, but the transport has not been attached yet.
      final secondOpen = Completer<void>();
      h.openGates[1] = secondOpen;

      await h.start();
      await h.connectFirst();
      await h.drop();

      h.controller.debugSetConnectedForTest(_params);
      await _pollUntil(
        () => h.opened.length == 2,
        'reconnect called the opener (open in flight)',
      );
      expect(h.saw(r's1$ '), isFalse, reason: 'second open must still be held');

      // The exact ordering the #1269 failure implied: the old shell's `done`
      // fires while the reconnect open is in flight. Let its handler run.
      h.opened.first.completeDone();
      await h.opened.first.done;
      await Future<void>.delayed(Duration.zero);

      secondOpen.complete();
      await _pollUntil(() => h.saw(r's1$ '), 'reconnect shell prompt s1');
      await h.expectLiveReconnectShell();
    },
  );
}
