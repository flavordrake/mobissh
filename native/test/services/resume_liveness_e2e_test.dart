// End-to-end resume liveness (#759).
//
// The #737 transport ping answers whenever SSH is up. But after deep Doze the
// link can be a zombie that still ACKs at the transport layer while the remote
// tmux/shell is FROZEN — a transport ping CANNOT catch an app-level freeze. The
// reported bug: on unlock after a long time away the session sat FROZEN with a
// green/connected dot until the user manually acted.
//
// The fix (owner CONFIRMED cause B): an END-TO-END liveness check on resume.
// When the transport ping answers but the session was STALE going into resume
// (no fresh remote bytes for a meaningful interval), the host sends a benign
// channel NUDGE (a no-op resize that makes a live tmux/shell REDRAW → fresh
// bytes) and waits a bounded window. A responsive shell answers with bytes →
// stays connected; a frozen one produces nothing → softDisconnected → reconnect.
//
// Conservative gate: ONLY (stale-before AND no-bytes-after-nudge) reconnects.
// A recently-active session, or one that answers the nudge, stays connected.
//
// Deterministic: real socket/network/wall-clock are all faked. A controllable
// clock (`nowMs`) drives the staleness gate; the fake shell transport optionally
// emits a redraw byte on resize to simulate a live vs frozen remote.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/diagnostics/connect_trace.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ssh/ssh_shell.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';

const _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

/// Silent socket so a real [SSHClient] can be constructed (non-null
/// `controller.client`) without any network IO or pending timers.
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

/// Controller exposing a non-null [client] sentinel + an injectable liveness
/// probe, with an inert `connect()` so the test owns the `connected` transition.
class _DrivableController extends SshSessionController {
  _DrivableController(
    this._client, {
    super.reconnectDelay,
    super.maxReconnectAttempts,
    super.livenessProbeOverride,
    super.reconnectAttemptOverride,
  });

  final SSHClient _client;

  @override
  SSHClient? get client => _client;

  @override
  Future<void> connect(SshConnectParams params) async {
    // Inert — tests drive `connected` via debugSetConnectedForTest.
  }
}

/// Fake PTY transport. Optionally emits a "redraw" byte each time it is resized
/// (a live tmux/shell answering the nudge). A frozen shell is constructed with
/// [redrawOnResize] = false → the nudge produces nothing.
class _FakeShellTransport implements SshShellTransport {
  _FakeShellTransport({required this.redrawOnResize});

  final bool redrawOnResize;
  final _outCtrl = StreamController<Uint8List>.broadcast();
  final _doneCompleter = Completer<void>();
  int resizeCount = 0;

  void emitByte() {
    if (!_outCtrl.isClosed) _outCtrl.add(Uint8List.fromList(const [0x40]));
  }

  @override
  Stream<Uint8List> get output => _outCtrl.stream;

  @override
  void send(Uint8List bytes) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    resizeCount += 1;
    // A live remote redraws on SIGWINCH; the nudge toggles dims twice but one
    // redraw byte is enough to prove responsiveness.
    if (redrawOnResize) scheduleMicrotask(emitByte);
  }

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  void close() {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
    if (!_outCtrl.isClosed) _outCtrl.close();
  }
}

void main() {
  setUp(clearConnectLog);

  /// Build a hosted, connected session with a fake shell open. Returns the
  /// controller + transport + a mutable clock so each test can drive staleness.
  Future<
    ({
      SessionHost host,
      InMemoryGatewayPair pair,
      _DrivableController controller,
      _FakeShellTransport transport,
      void Function(int) setClock,
      List<String> reconnects,
    })
  >
  buildConnected({
    required bool redrawOnResize,
    required LivenessProbe probe,
  }) async {
    const sid = 'h:22:u:1';
    final socket = _SilentSocket();
    final sentinel = SSHClient(socket, username: 'u');

    var clock = 0;
    final reconnects = <String>[];

    late _DrivableController controller;
    _DrivableController factory() {
      controller = _DrivableController(
        sentinel,
        reconnectDelay: Duration.zero,
        maxReconnectAttempts: 3,
        livenessProbeOverride: probe,
        reconnectAttemptOverride: (p) async {
          reconnects.add('reconnect:${p.host}');
          return true;
        },
      );
      return controller;
    }

    final transport = _FakeShellTransport(redrawOnResize: redrawOnResize);
    Future<SshShellTransport?> opener(SSHClient c, int cols, int rows) async =>
        transport;

    final pair = InMemoryGatewayPair();
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: factory,
      shellOpener: opener,
      snapshotInterval: const Duration(hours: 1),
      resumeProbeTimeout: const Duration(milliseconds: 30),
      resumeStaleThreshold: const Duration(seconds: 20),
      resumeNudgeWindow: const Duration(milliseconds: 60),
      nowMs: () => clock,
    );

    pair.uiSide.send(
      const SshConnectCommand(
        sessionId: sid,
        host: 'h',
        port: 22,
        username: 'u',
        authJson: {'type': 'password', 'password': 'p'},
      ).toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    controller.debugSetConnectedForTest(_params);
    // Let the state listener open the shell.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(controller.data.state, SshSessionState.connected);

    return (
      host: host,
      pair: pair,
      controller: controller,
      transport: transport,
      setClock: (int v) => clock = v,
      reconnects: reconnects,
    );
  }

  void sendResume(InMemoryGatewayPair pair) {
    pair.uiSide.send(
      const SshResumeProbeCommand(sessionId: 'h:22:u:1').toJson(),
    );
  }

  test(
    'ping-alive + STALE + no-bytes-after-nudge → softDisconnected → reconnect '
    '(#759)',
    () async {
      final ctx = await buildConnected(
        redrawOnResize: false, // frozen shell — nudge produces nothing
        probe: () async {}, // transport ping answers
      );
      addTearDown(() async {
        await ctx.host.dispose();
        await ctx.pair.dispose();
      });

      // Advance the clock past the stale threshold since the last (open-prompt)
      // byte so the session is STALE going into resume.
      ctx.setClock(60000);

      final states = <SshSessionState>[];
      final sub = ctx.controller.stream.listen((d) => states.add(d.state));
      addTearDown(sub.cancel);

      sendResume(ctx.pair);
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (ctx.reconnects.isNotEmpty) break;
      }

      expect(
        states,
        contains(SshSessionState.softDisconnected),
        reason: 'a transport-alive but frozen shell must soft-disconnect',
      );
      expect(
        ctx.reconnects,
        contains('reconnect:h'),
        reason: 'the #759 stale-no-redraw case must reconnect',
      );
      expect(
        lifecycleLogSnapshot().join('\n'),
        contains('STALE(no-bytes-after-nudge) → reconnect'),
        reason: 'the stale-reconnect outcome must be in the lifecycle ring',
      );
    },
  );

  test(
    'ping-alive + STALE + fresh-bytes-after-nudge → stays connected (#759)',
    () async {
      final ctx = await buildConnected(
        redrawOnResize: true, // live shell answers the nudge
        probe: () async {},
      );
      addTearDown(() async {
        await ctx.host.dispose();
        await ctx.pair.dispose();
      });

      ctx.setClock(60000); // stale-before

      sendResume(ctx.pair);
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(
        ctx.controller.data.state,
        SshSessionState.connected,
        reason: 'a live shell that redraws on the nudge must stay connected',
      );
      expect(ctx.reconnects, isEmpty);
      expect(
        lifecycleLogSnapshot().join('\n'),
        contains('alive(fresh-bytes-after-nudge)'),
      );
    },
  );

  test('ping-FAILS → reconnect (#737 still works)', () async {
    final ctx = await buildConnected(
      redrawOnResize: false,
      probe: () => Completer<void>().future, // dead half-open socket
    );
    addTearDown(() async {
      await ctx.host.dispose();
      await ctx.pair.dispose();
    });

    ctx.setClock(60000);
    sendResume(ctx.pair);
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (ctx.reconnects.isNotEmpty) break;
    }

    expect(
      ctx.reconnects,
      contains('reconnect:h'),
      reason: 'a failed transport ping must still reconnect (#737)',
    );
    expect(
      lifecycleLogSnapshot().join('\n'),
      contains('ping-failed → reconnect'),
    );
  });

  test(
    'recently-active session (NOT stale) → no spurious reconnect, no nudge',
    () async {
      final ctx = await buildConnected(
        redrawOnResize: false, // even a "silent" shell must NOT reconnect here
        probe: () async {},
      );
      addTearDown(() async {
        await ctx.host.dispose();
        await ctx.pair.dispose();
      });

      // Ingest a fresh remote byte right before resume so lastRemoteByteAtMs is
      // recent relative to the (unchanged) clock — NOT stale.
      ctx.setClock(1000);
      ctx.host.ingestOutputForTest(
        'h:22:u:1',
        Uint8List.fromList(const [0x41]),
      );

      final resizesBefore = ctx.transport.resizeCount;
      sendResume(ctx.pair);
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(
        ctx.controller.data.state,
        SshSessionState.connected,
        reason: 'a recently-active session must not be reconnected on resume',
      );
      expect(ctx.reconnects, isEmpty);
      expect(
        ctx.transport.resizeCount,
        resizesBefore,
        reason: 'a non-stale session must NOT be nudged (conservative gate)',
      );
      expect(
        lifecycleLogSnapshot().join('\n'),
        contains('alive(recent-bytes)'),
      );
    },
  );
}
